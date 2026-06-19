#!/usr/bin/env bash

set -euo pipefail

if [[ -z "${PSPDEV:-}" ]]; then
  echo "ERROR: PSPDEV must be set before normalizing PSP archives."
  exit 1
fi

LIB_DIR="${PSPDEV}/psp/lib"
if [[ ! -d "${LIB_DIR}" ]]; then
  echo "No PSP library directory found at ${LIB_DIR}; skipping archive normalization."
  exit 0
fi

find_tool() {
  local tool="$1"
  if command -v "${tool}" >/dev/null 2>&1; then
    command -v "${tool}"
    return 0
  fi

  if command -v brew >/dev/null 2>&1; then
    local brew_llvm
    brew_llvm="$(brew --prefix llvm 2>/dev/null || true)"
    if [[ -n "${brew_llvm}" && -x "${brew_llvm}/bin/${tool}" ]]; then
      echo "${brew_llvm}/bin/${tool}"
      return 0
    fi
  fi

  for prefix in /opt/homebrew/opt/llvm /usr/local/opt/llvm; do
    if [[ -x "${prefix}/bin/${tool}" ]]; then
      echo "${prefix}/bin/${tool}"
      return 0
    fi
  done

  echo "ERROR: ${tool} not found. Install LLVM before running this step." >&2
  return 1
}

LLVM_AR="$(find_tool llvm-ar)"
LLVM_RANLIB="$(find_tool llvm-ranlib)"
LLVM_READELF="$(find_tool llvm-readelf)"
LLVM_OBJCOPY="$(find_tool llvm-objcopy)"

if ! command -v perl >/dev/null 2>&1; then
  echo "ERROR: perl not found. A system Perl is required for ELF metadata normalization."
  exit 1
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pspdev-normalize-archives.XXXXXX")"
trap 'rm -rf "${WORK_DIR}"' EXIT

PATCH_ELF="${WORK_DIR}/patch-mips-psp-elf.pl"
cat > "${PATCH_ELF}" <<'PERL'
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

    # Clang's MIPS objects can carry machine-extension and single-float metadata
    # that rust-lld rejects when linked with rustc's current mipsel-sony-psp
    # objects. Match the metadata shape emitted by rustc and the legacy PSP SDK:
    # MIPS2 O32, no machine extension, hard-float double ABI.
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
                    next unless $name eq ".MIPS.abiflags";

                    my $off = unpack("V", substr($data, $sh + 16, 4));
                    my $size = unpack("V", substr($data, $sh + 20, 4));
                    next if $size < 24 || $off + $size > length($data);
                    substr($data, $off + 7, 1) = "\x01";       # Val_GNU_MIPS_ABI_FP_DOUBLE
                    substr($data, $off + 8, 4) = pack("V", 0); # ISA extension: none
                    substr($data, $off + 12, 4) = pack("V", 0); # ASEs: none
                    substr($data, $off + 16, 4) = pack("V", 1); # FLAGS1: odd single-precision regs
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

normalize_archive() {
  local archive="$1"
  local name
  name="$(basename "${archive}")"
  local archive_dir="${WORK_DIR}/${name%.a}"
  mkdir -p "${archive_dir}"

  (
    cd "${archive_dir}"
    "${LLVM_AR}" x "${archive}"
  )

  local member_list="${WORK_DIR}/${name%.a}.members"
  find "${archive_dir}" -type f | sort > "${member_list}"
  if [[ ! -s "${member_list}" ]]; then
    echo "Skipping empty PSP archive: ${name}"
    return
  fi

  local changed=0
  while IFS= read -r obj; do
    local file_symbols
    file_symbols="$("${LLVM_READELF}" -s "${obj}" 2>/dev/null | awk '$4 == "FILE" && $5 == "LOCAL" && $8 != "" { print $8 }' | sort -u || true)"
    if [[ -n "${file_symbols}" ]]; then
      changed=1
      local strip_args=()
      while IFS= read -r sym; do
        strip_args+=("--strip-symbol=${sym}")
      done <<< "${file_symbols}"
      "${LLVM_OBJCOPY}" "${strip_args[@]}" "${obj}"
    fi
  done < "${member_list}"

  while IFS= read -r obj; do
    perl "${PATCH_ELF}" "${obj}"
  done < "${member_list}"

  rm -f "${archive}"
  local members=()
  while IFS= read -r obj; do
    members+=("${obj#${archive_dir}/}")
  done < "${member_list}"
  (
    cd "${archive_dir}"
    "${LLVM_AR}" rc "${archive}" "${members[@]}"
  )
  "${LLVM_RANLIB}" "${archive}"

  if [[ "${changed}" -eq 1 ]]; then
    echo "Normalized PSP archive symbols and metadata: ${name}"
  else
    echo "Normalized PSP archive metadata: ${name}"
  fi
}

for archive in "${LIB_DIR}"/*.a; do
  [[ -e "${archive}" ]] || continue
  normalize_archive "${archive}"
done
