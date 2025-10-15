<div align="center">

# DecryptBinary

**A tool for decrypting iOS application binaries**


</div>

---

## Features

- List all running applications
- Decrypt application binaries with ease
- Target specific apps by bundle ID
- Support for both rootful and rootless jailbreaks

## Quick Start

### List Running Applications

```bash
decryptbinary -l
```

### Decrypt an Application

**Rootful Jailbreak:**
```bash
decryptbinary -d <bundle_id>
```

**Rootless Jailbreak:**
```bash
sudo decryptbinary -d <bundle_id>
```

## Output Location

Decrypted binaries are automatically saved to:

```
<app_data_directory>/Documents/<app_name>.decrypted
```

## Requirements

### Runtime Requirements
- Jailbroken iOS device
  - **Rootful :** MobileSubstrate
  - **Rootless :** ElleKit

> **Note:** If you don't have the required tweak injection framework installed, you can install it via terminal:
> ```bash
> # For Rootful (MobileSubstrate)
> apt install mobilesubstrate
>
> # For Rootless (ElleKit)
> apt install ellekit
> ```

### Build Requirements
- [Theos](https://theos.dev/) development environment

## Installation

### From Pre-built Package

**Rootful:**
```bash
dpkg -i com.merona.decryptbinary_*.deb
```

**Rootless:**
```bash
sudo dpkg -i com.merona.decryptbinary_*.deb
```

## Building from Source

**Rootful:**
```bash
make clean && make package
```

**Rootless:**
```bash
make clean && make package ROOTLESS=1
```
