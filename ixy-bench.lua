local mg     = require "moongen"
local memory = require "memory"
local device = require "device"
local ts     = require "timestamping"
local filter = require "filter"
local hist   = require "histogram"
local stats  = require "stats"
local timer  = require "timer"
local arp    = require "proto.arp"
local log    = require "log"

local SRC_IP1 = "10.0.0.1"
local SRC_IP2 = "10.128.0.1"
local DST_IP2 = "10.0.0.1"
local DST_IP1 = "10.128.0.1"

local SRC_PORT = 1234
local DST_PORT = 319


function configure(parser)
	parser:description("ixy benchmarking script: generates bidirectional UDP traffic and checks reception order and latency.")
	parser:argument("dev1", "Device 1."):convert(tonumber)
	parser:argument("dev2", "Device 2."):convert(tonumber)
	parser:option("-r --rate", "Transmit rate in Mbit/s."):default(0):convert(tonumber)
	parser:option("-f --flows", "Number of flows (randomized source IP)."):default(1024):convert(tonumber)
	parser:option("-s --size", "Packet size."):default(60):convert(tonumber)
	parser:option("--dev1-stats-file", "Write IO statistics for device 1 to a CSV file"):target("stats1")
	parser:option("--dev2-stats-file", "Write IO statistics for device 2 to a CSV file"):target("stats2")
	parser:flag("-v --verify", "Try to receive packets and validate sequence numbers."):default(false)
	parser:flag("-t --timestamps", "Take hardware timestamps of 1000 packets per second."):default(false)
end

function master(args)
	local dev1 = device.config{port = args.dev1, rxQueues = 2, txQueues = 2}
	local dev2 = device.config{port = args.dev2, rxQueues = 2, txQueues = 2}
	device.waitForLinks()
	if args.rate > 0 then
		local timestampTrafficAdjuster = args.timestamps and (args.size + 4) * 8 / 1000 or 0
		dev1:getTxQueue(0):setRate(args.rate - timestampTrafficAdjuster)
		dev2:getTxQueue(0):setRate(args.rate - timestampTrafficAdjuster)
	end
	mg.startTask("loadSlave", dev1:getTxQueue(0), SRC_IP1, DST_IP1, dev2:getMacString(), args.size, args.flows)
	mg.startTask("loadSlave", dev2:getTxQueue(0), SRC_IP2, DST_IP2, dev1:getMacString(), args.size, args.flows)
	if args.verify then
		mg.startTask("sequenceCheck", dev1:getRxQueue(0), dev2:getRxQueue(0))
	end
	if args.timestamps then
		mg.startSharedTask("timerSlave",
			dev1:getTxQueue(1), dev2:getRxQueue(1),
			SRC_IP1, DST_IP1, dev2:getMacString(),
			dev2:getTxQueue(1), dev1:getRxQueue(1),
			SRC_IP2, DST_IP2, dev1:getMacString(),
			args.size, args.flows
		)
	end
	stats.startStatsTask{
		devices = {
			args.stats1 and { dev = dev1, file = args.stats1, format = "csv" } or dev1,
			args.stats2 and { dev = dev2, file = args.stats2, format = "csv" } or dev2,
		}
	}
	mg.waitForTasks()
end

local function fillUdpPacket(buf, len, srcIp, dstIp, dstMac)
	buf:getUdpPacket():fill{
		ethSrc = queue,
		ethDst = dstMac,
		ip4Src = srcIp,
		ip4Dst = dstIp,
		udpSrc = SRC_PORT,
		udpDst = DST_PORT,
		pktLength = len
	}
end

function loadSlave(queue, srcIp, dstIp, dstMac, size, flows)
	local mempool = memory.createMemPool(function(buf)
		fillUdpPacket(buf, size, srcIp, dstIp, dstMac)
	end)
	local bufs = mempool:bufArray()
	local baseIP = parseIPAddress(srcIp)
	local flowId = 0
	local seq = 1
	while mg.running() do
		bufs:alloc(size)
		for i, buf in ipairs(bufs) do
			local pkt = buf:getUdpPacket()
			pkt.ip4.src:set(baseIP + flowId)
			-- yes, this is 1 and 0 on purpose; the beginning might otherwise be interpreted as PTP by the hardware
			pkt.payload.uint64[1] = seq
			seq = seq + 1
			flowId = incAndWrap(flowId, flows)
		end
		bufs:offloadIPChecksums()
		queue:send(bufs)
	end
end

-- try to check sequence numbers, this doesn't need to receive all packets
-- just a "random" subset is fine (also saves PCIe bandwidth)
local function checkSequence(queue, bufs, last)
	local n = queue:tryRecv(bufs, 100)
	for i = 1, n do
		local buf = bufs[i]
		local pkt = buf:getUdpPacket()
		local seq = pkt.payload.uint64[1]
		if seq > last then
			last = seq
		else
			log:warn("Packet duplicated or re-ordered: got seq %s, expected > %s", tostring(seq), tostring(last))
		end
	end
	bufs:free(n)
	return last
end

function sequenceCheck(rxQueue1, rxQueue2)
	log:info("Verifying received sequence numbers...")
	local bufs = memory.createBufArray()
	local last1 = 0
	local last2 = 0
	while mg.running() do
		last1 = checkSequence(rxQueue1, bufs, last1)
		last2 = checkSequence(rxQueue2, bufs, last2)
	end
end

function timerSlave(
	txQueue1, rxQueue1, srcIp1, dstIp1, dstMac1,
	txQueue2, rxQueue2, srcIp2, dstIp2, dstMac2,
	size, flows
)
	if size < 84 then
--		log:warn("Packet size %d is smaller than minimum timestamp size 84. Timestamped packets will be larger than load packets.", size)
		size = 84
	end
	local timestamper1 = ts:newUdpTimestamper(txQueue1, rxQueue1)
	local timestamper2 = ts:newUdpTimestamper(txQueue2, rxQueue2)
	local hist1 = hist:new()
	local hist2 = hist:new()
	local hist = hist:new()
	mg.sleepMillis(500) -- ensure that the load task is running
	local flowId = 0
	local rateLimit = timer:new(0.001)
	local srcIp1Base = parseIPAddress(srcIp1)
	local srcIp2Base = parseIPAddress(srcIp2)
	while mg.running() do
		local lat1 = timestamper1:measureLatency(size, function(buf)
			fillUdpPacket(buf, size, srcIp1, dstIp1, dstMac1)
			local pkt = buf:getUdpPacket()
			pkt.ip4.src:set(srcIp1Base + flowId)
		end)
		local lat2 = timestamper2:measureLatency(size, function(buf)
			fillUdpPacket(buf, size, srcIp2, dstIp2, dstMac2)
			local pkt = buf:getUdpPacket()
			pkt.ip4.src:set(srcIp2Base + flowId)
		end)
		flowId = incAndWrap(flowId, flows)
		hist1:update(lat1)
		hist2:update(lat2)
		hist:update(lat1)
		hist:update(lat2)
		rateLimit:wait()
		rateLimit:reset()
	end
	mg.sleepMillis(300)
	hist:save("hist-combined.csv")
	hist1:save("hist-direction1.csv")
	hist2:save("hist-direction2.csv")
	hist1:print()
	hist2:print()
	hist:print()
end

