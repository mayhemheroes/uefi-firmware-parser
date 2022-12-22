#!/usr/bin/env python3

import atheris
import sys
import fuzz_helpers

with atheris.instrument_imports(include=["uefi_firmware"]):
    import uefi_firmware

@atheris.instrument_func
def TestOneInput(data):
    if len(data) < 20:
        return -1
    fdp = fuzz_helpers.EnhancedFuzzedDataProvider(data)
    try:
        if fdp.ConsumeBool():
            parser = uefi_firmware.AutoParser(fdp.ConsumeRemainingBytes())
            if parser.type() != 'unknown':
                firmware = uefi_firmware.parse()
                firmware.showinfo()
        else:
            buff = fdp.ConsumeRemainingBytes()
            comp_buff = uefi_firmware.efi_compressor.LzmaDecompress(
                    buff, len(buff))
            decomp_buff = uefi_firmware.efi_compressor.LzmaDecompress(
                    comp_buff, len(comp_buff))
            if len(decomp_buff) != len(buff) or buff != decomp_buff:
                raise RuntimeError("Decompression failed!")
    except Exception as e:
        if 'decompress' in str(e):
            return -1
        raise


def main():
    atheris.Setup(sys.argv, TestOneInput)
    atheris.Fuzz()


if __name__ == "__main__":
    main()
