#!/bin/bash
# psplinkusb by fjtrujy

## Download the source code.
REPO_URL="https://github.com/pspdev/psplinkusb"
REPO_FOLDER="psplinkusb"
BRANCH_NAME="master"
if test ! -d "$REPO_FOLDER"; then
	git clone --depth 1 -b $BRANCH_NAME $REPO_URL && cd $REPO_FOLDER || { exit 1; }
else
	cd $REPO_FOLDER && git fetch origin && git reset --hard origin/${BRANCH_NAME} || { exit 1; }
fi

## The clang-built SDK archives are normalized to rustc-compatible double-float
## metadata. Keep psplinkusb's PSP-side object metadata consistent with those
## archives so BFD ld does not warn while linking these helper PRX/ELF files.
## Do this after compilation instead of changing CFLAGS, because psplinkusb
## contains real float/double code and should keep its original codegen.
NORMALIZE_OBJECTS="$PWD/normalize-psp-object-metadata.sh"
cat > "$NORMALIZE_OBJECTS" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

[[ "$#" -eq 0 ]] && exit 0

perl - "$@" <<'PERL'
use strict;
use warnings;

for my $path (@ARGV) {
    open(my $fh, "+<:raw", $path) or die "open $path: $!";
    local $/;
    my $data = <$fh>;
    next unless length($data) >= 52;
    next unless substr($data, 0, 4) eq "\x7fELF";
    next unless unpack("C", substr($data, 4, 1)) == 1; # ELFCLASS32
    next unless unpack("C", substr($data, 5, 1)) == 1; # ELFDATA2LSB
    next unless unpack("v", substr($data, 18, 2)) == 8; # EM_MIPS

    my $flags = unpack("V", substr($data, 36, 4));
    substr($data, 36, 4) = pack("V", $flags & 0xf000ffff);

    my $shoff = unpack("V", substr($data, 32, 4));
    my $shentsize = unpack("v", substr($data, 46, 2));
    my $shnum = unpack("v", substr($data, 48, 2));
    my $shstrndx = unpack("v", substr($data, 50, 2));
    if ($shoff && $shentsize && $shstrndx < $shnum) {
        my $shstr = $shoff + $shstrndx * $shentsize;
        if ($shstr + 24 <= length($data)) {
            my $shstr_off = unpack("V", substr($data, $shstr + 16, 4));
            my $shstr_size = unpack("V", substr($data, $shstr + 20, 4));
            my $shstr_end = $shstr_off + $shstr_size;
            if ($shstr_end <= length($data)) {
                for (my $i = 0; $i < $shnum; $i++) {
                    my $sh = $shoff + $i * $shentsize;
                    next if $sh + 24 > length($data);
                    my $name_off = unpack("V", substr($data, $sh, 4));
                    my $name_start = $shstr_off + $name_off;
                    next if $name_start >= $shstr_end;
                    my $name_end = index($data, "\0", $name_start);
                    next if $name_end < 0 || $name_end > $shstr_end;
                    my $name = substr($data, $name_start, $name_end - $name_start);

                    if ($name eq ".MIPS.abiflags") {
                        my $off = unpack("V", substr($data, $sh + 16, 4));
                        my $size = unpack("V", substr($data, $sh + 20, 4));
                        next if $size < 24 || $off + $size > length($data);
                        substr($data, $off + 7, 1) = "\x01";
                        substr($data, $off + 8, 4) = pack("V", 0);
                        substr($data, $off + 12, 4) = pack("V", 0);
                        substr($data, $off + 16, 4) = pack("V", 1);
                    }

                    if ($name eq ".gnu.attributes") {
                        my $off = unpack("V", substr($data, $sh + 16, 4));
                        my $size = unpack("V", substr($data, $sh + 20, 4));
                        next if $off + $size > length($data);
                        my $attrs = substr($data, $off, $size);
                        $attrs =~ s/\x04\x02/\x04\x01/g;
                        substr($data, $off, $size) = $attrs;
                    }
                }
            }
        }
    }

    seek($fh, 0, 0) or die "seek $path: $!";
    print {$fh} $data or die "write $path: $!";
    truncate($fh, length($data)) or die "truncate $path: $!";
    close($fh) or die "close $path: $!";
}
PERL
EOF
chmod +x "$NORMALIZE_OBJECTS"
export PSPLINKUSB_NORMALIZE_OBJECTS="$NORMALIZE_OBJECTS"

while IFS= read -r MAKEFILE; do
	perl -0pi -e 's/(\nPSPSDK=\$\(shell psp-config --pspsdk-path\)\ninclude \$\(PSPSDK\)\/lib\/build[^ \n]*\.mak\n)/$1\n.PHONY: normalize-psp-objects\n\$(TARGET).elf: | normalize-psp-objects\nnormalize-psp-objects: \$(OBJS) \$(EXPORT_OBJ)\n\t\$(PSPLINKUSB_NORMALIZE_OBJECTS) \$(OBJS) \$(EXPORT_OBJ)\n/s' "$MAKEFILE"
done < <(find . -name Makefile -type f -exec grep -l '\$(PSPSDK)/lib/build' {} +)

for MAKEFILE in libpsplink/Makefile libpsplink_driver/Makefile libusbhostfs/Makefile libusbhostfs_driver/Makefile; do
	perl -0pi -e 's/\n\$\((TARGET)\): \$\((OBJS)\)/\n.PHONY: normalize-psp-objects\nnormalize-psp-objects: \$(OBJS)\n\t\$(PSPLINKUSB_NORMALIZE_OBJECTS) \$(OBJS)\n\n\$(TARGET): \$(OBJS) | normalize-psp-objects/' "$MAKEFILE"
done

## Determine the maximum number of processes that Make can work with.
PROC_NR=$(getconf _NPROCESSORS_ONLN)
OSVER=$(uname)

## Compile and install.
make --quiet -j $PROC_NR clean          			|| { exit 1; }
make --quiet -j $PROC_NR all            			|| { exit 1; }
# WIndows currently can't compile pspsh, usbhostfs_pc
if [ "${OSVER:0:5}" != MINGW ]; then
	make --quiet -j $PROC_NR -C pspsh install 			|| { exit 1; }
	make --quiet -j $PROC_NR -C usbhostfs_pc install 	|| { exit 1; }
fi

## Store build information
BUILD_FILE="${PSPDEV}/build.txt"
if [[ -f "${BUILD_FILE}" ]]; then
  sed -i'' '/^psplinkusb /d' "${BUILD_FILE}"
fi
git log -1 --format="psplinkusb %H %cs %s" >> "${BUILD_FILE}"
