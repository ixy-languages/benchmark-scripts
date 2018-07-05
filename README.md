Installation
============

```
git clone --recursive https://github.com/emmericp/MoonGen
cd MoonGen
./build.sh
sudo ./setup-hugetlbfs.sh
sudo ./bind-interfaces.sh
./build/MoonGen <path-to-this-repo>/ixy-bench.lua --rate XXX <port1> <port2>
```

Check `MoonGen/README.md` for build dependencies of MoonGen (on Debian/Ubuntu: `sudo apt-get install -y build-essential cmake linux-headers-`uname -r` pciutils libnuma-dev`)

