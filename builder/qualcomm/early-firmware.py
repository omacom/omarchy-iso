#!/usr/bin/env python3
"""List firmware named by the device trees embedded in the Qualcomm live UKI."""
from pathlib import Path
import struct
import sys

OWNERS = {'qcom,x1e80100-adsp-pas', 'qcom,sc8280xp-adsp-pas', 'qcom,glymur-soccp-pas'}

def properties(data):
    """Walk flattened-device-tree properties without running target programs."""
    magic = data.find(b'\xd0\x0d\xfe\xed', 0, 4096)
    if magic < 0:
        raise RuntimeError('No flattened device tree header')
    data = data[magic:]
    header = struct.unpack_from('>10I', data)
    _, total, pos, strings, _, _, _, _, strings_size, structure_size = header
    if total > len(data) or strings + strings_size > total or pos + structure_size > total:
        raise RuntimeError('Truncated device tree')
    end = pos + structure_size
    names = data[strings:strings + strings_size]
    stack, result = [], {}
    while pos + 4 <= end:
        token, = struct.unpack_from('>I', data, pos); pos += 4
        if token == 1:
            terminator = data.find(b'\0', pos, end)
            if terminator < 0:
                raise RuntimeError('Invalid DT node name')
            stack.append(data[pos:terminator].decode())
            result['/'.join(stack)] = {}
            pos = (terminator + 4) & ~3
        elif token == 2:
            stack.pop()
        elif token == 3:
            length, nameoff = struct.unpack_from('>II', data, pos); pos += 8
            if pos + length > end or nameoff >= len(names):
                raise RuntimeError('Invalid DT property')
            nameend = names.find(b'\0', nameoff)
            if nameend < 0:
                raise RuntimeError('Invalid DT property name')
            name = names[nameoff:nameend].decode()
            result['/'.join(stack)][name] = data[pos:pos + length]
            pos = (pos + length + 3) & ~3
        elif token == 4:
            pass
        elif token == 9:
            return result
        else:
            raise RuntimeError('Invalid DT token')
    raise RuntimeError('Missing DT end token')


def strings(value):
    return [s.decode() for s in value.rstrip(b'\0').split(b'\0') if s]


def firmware_inventory(dtbs):
    inventory = []
    for dtb in dtbs:
        nodes = properties(dtb)
        required, optional = set(), set()
        owner = False
        for node in nodes.values():
            if node.get('status', b'okay\0').rstrip(b'\0') not in (b'okay', b'ok'):
                continue
            compatible = set(strings(node.get('compatible', b'')))
            files = set(strings(node.get('firmware-name', b'')))
            if compatible & OWNERS:
                # Glymur's early-boot SOCCP attaches to firmware supplied by
                # UEFI. Its DT names are a fallback, not required for attach.
                if 'qcom,glymur-soccp-pas' in compatible:
                    optional.update(files)
                else:
                    required.update(files)
                owner = True
            else:
                optional.update(files)
        if owner:
            inventory.append({'model': strings(nodes[''].get('model', b'unknown'))[0],
                              'required': sorted(required), 'optional': sorted(optional)})
    if not inventory:
        raise RuntimeError('No supported Qualcomm firmware owner in source DTBs')
    return inventory


def main():
    dtbs = [Path(line) for line in Path(sys.argv[1]).read_text().splitlines()]
    inventory = firmware_inventory([path.read_bytes() for path in dtbs])
    names = sorted({name for board in inventory for name in board['required'] + board['optional']})
    for name in names:
        if Path(name).is_absolute() or '..' in Path(name).parts or any(c in name for c in '*?[]\\\n\r'):
            raise RuntimeError('Unsafe device-tree firmware name: ' + repr(name))
        print(name)

if __name__ == '__main__':
    main()
