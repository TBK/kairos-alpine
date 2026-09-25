# Build sb-enroll.efi with gnu-efi for the host architecture.
ARCH    := $(shell uname -m)
EFIINC  := /usr/include/efi
EFILIB  := /usr/lib
CFLAGS  := -I$(EFIINC) -I$(EFIINC)/$(ARCH) -I$(EFIINC)/protocol -O2 -Wall -Werror \
           -fpic -ffreestanding -fno-stack-protector -fno-stack-check -fshort-wchar \
           -fno-strict-aliasing -DGNU_EFI_USE_MS_ABI
ifeq ($(ARCH),x86_64)
CFLAGS  += -mno-red-zone -maccumulate-outgoing-args
FORMAT  := --target efi-app-x86_64
else
FORMAT  := --target efi-app-$(ARCH)
endif
LDFLAGS := -nostdlib -znocombreloc -shared -Bsymbolic -T $(EFILIB)/elf_$(ARCH)_efi.lds \
           -L$(EFILIB) $(EFILIB)/crt0-efi-$(ARCH).o

sb-enroll.efi: sb-enroll.so
	objcopy -j .text -j .sdata -j .data -j .rodata -j .dynamic -j .dynsym \
	        -j .rel -j .rela -j '.rel.*' -j '.rela.*' -j .reloc \
	        $(FORMAT) --subsystem=10 $< $@

sb-enroll.so: sb-enroll.o
	ld $(LDFLAGS) $< -o $@ -lefi -lgnuefi

sb-enroll.o: sb-enroll.c
	gcc $(CFLAGS) -c $< -o $@

clean:
	rm -f sb-enroll.o sb-enroll.so sb-enroll.efi
