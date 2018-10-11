Installation
============

```
git clone --recursive https://github.com/emmericp/MoonGen
cd MoonGen
./build.sh
sudo ./setup-hugetlbfs.sh
sudo ./bind-interfaces.sh
./build/MoonGen <path-to-this-repo>/ixy-bench.lua --help
```

Check `MoonGen/README.md` for build dependencies of MoonGen (on Debian/Ubuntu: `sudo apt-get install -y build-essential cmake linux-headers-`uname -r` pciutils libnuma-dev`)

Testing the forwarder
=====================

Run the script with `--verify` to check if the forwarder works properly by validating the sequence numbers.
This might affect performance of the packet generator process due to bottlenecks on the generating NIC which might not support sending an receiving at full line rate at the same time.
Do not use this option to measure performance.

Latency measurements
====================

Run the script with `--timestamps` to sample latency measurements using hardware timestamping.
This is based on samples of the traffic and might not be suitable to characterize some effects like JIT warmup times of VM-based languages.
A full setup utilizing MoonSniff on X552 NICs timestamping every single packet via fiber splitters is work in progress.
