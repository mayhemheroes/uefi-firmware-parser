#!/usr/bin/env python3

import atheris
import sys
import fuzz_helpers

with atheris.instrument_imports(include=["uefi_firmware"]):
    import uefi_firmware

def TestOneInput(data):
    fdp = fuzz_helpers.EnhancedFuzzedDataProvider(data)
    try:
        uefi_firmware.AutoParser(fdp.ConsumeRemainingBytes())
    except:
        return -1


def main():
    atheris.Setup(sys.argv, TestOneInput)
    atheris.Fuzz()


if __name__ == "__main__":
    main()
