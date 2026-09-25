/*
 * sb-enroll: enroll Secure Boot keys from \EFI\sbkeys\ on the boot medium.
 *
 * The firmware must be in Setup Mode (no PK enrolled). The tool writes the
 * pre-signed variable updates made by secureboot/genkeys.sh, in this order:
 *   db  (own cert, optionally + Microsoft UEFI CAs)
 *   dbx (Microsoft revocation list, only together with the Microsoft certs)
 *   KEK (own cert, optionally + Microsoft KEKs)
 *   PK  (last: this ends Setup Mode and turns Secure Boot on)
 * If any write fails it stops before PK, so the machine stays in Setup Mode.
 */
#include <efi.h>
#include <efilib.h>

#if defined(__x86_64__)
#define ARCH_SUFFIX L"x64"
#elif defined(__aarch64__)
#define ARCH_SUFFIX L"aa64"
#elif defined(__riscv) && __riscv_xlen == 64
#define ARCH_SUFFIX L"riscv64"
#else
#error unsupported architecture
#endif

#define KEYDIR L"\\EFI\\sbkeys\\"
#define AUTH_ATTRS (EFI_VARIABLE_NON_VOLATILE | EFI_VARIABLE_BOOTSERVICE_ACCESS | \
                    EFI_VARIABLE_RUNTIME_ACCESS | EFI_VARIABLE_TIME_BASED_AUTHENTICATED_WRITE_ACCESS)
#ifndef EFI_VARIABLE_APPEND_WRITE
#define EFI_VARIABLE_APPEND_WRITE 0x00000040
#endif

static EFI_GUID global_guid = EFI_GLOBAL_VARIABLE;
static EFI_GUID secdb_guid = { 0xd719b2cb, 0x3d3a, 0x4596, { 0xa3, 0xbc, 0xda, 0xd0, 0x0e, 0x67, 0x65, 0x6f } };

static EFI_FILE_HANDLE root;

/* Returns the variable's value, or -1 if it doesn't exist. */
static INTN get_u8(CHAR16 *name)
{
	UINT8 v = 0;
	UINTN size = sizeof(v);
	UINT32 attr;
	EFI_STATUS s = uefi_call_wrapper(RT->GetVariable, 5, name, &global_guid, &attr, &size, &v);
	return EFI_ERROR(s) ? -1 : v;
}

static UINT64 get_u64(CHAR16 *name)
{
	UINT64 v = 0;
	UINTN size = sizeof(v);
	UINT32 attr;
	EFI_STATUS s = uefi_call_wrapper(RT->GetVariable, 5, name, &global_guid, &attr, &size, &v);
	return EFI_ERROR(s) ? 0 : v;
}

static CHAR16 get_key(void)
{
	EFI_INPUT_KEY key;
	UINTN idx;
	for (;;) {
		uefi_call_wrapper(BS->WaitForEvent, 3, 1, &ST->ConIn->WaitForKey, &idx);
		if (!EFI_ERROR(uefi_call_wrapper(ST->ConIn->ReadKeyStroke, 2, ST->ConIn, &key)))
			break;
	}
	if (key.UnicodeChar >= L'A' && key.UnicodeChar <= L'Z')
		key.UnicodeChar += L'a' - L'A';
	return key.UnicodeChar;
}

/* Prompt; Enter returns def. */
static BOOLEAN ask(CHAR16 *question, BOOLEAN def)
{
	Print(L"%s [%s] ", question, def ? L"Y/n" : L"y/N");
	for (;;) {
		CHAR16 c = get_key();
		if (c == L'y' || (def && (c == L'\r' || c == L'\n'))) { Print(L"yes\n"); return TRUE; }
		if (c == L'n' || (!def && (c == L'\r' || c == L'\n'))) { Print(L"no\n"); return FALSE; }
	}
}

/* Reads KEYDIR<name>; returns NULL if it doesn't exist. */
static VOID *read_file(CHAR16 *name, UINTN *size)
{
	CHAR16 path[128];
	EFI_FILE_HANDLE fh;
	EFI_FILE_INFO *info;
	VOID *buf;

	SPrint(path, sizeof(path), L"%s%s", KEYDIR, name);
	if (EFI_ERROR(uefi_call_wrapper(root->Open, 5, root, &fh, path, EFI_FILE_MODE_READ, 0)))
		return NULL;
	info = LibFileInfo(fh);
	if (!info) {
		uefi_call_wrapper(fh->Close, 1, fh);
		return NULL;
	}
	*size = info->FileSize;
	FreePool(info);
	buf = AllocatePool(*size);
	if (buf && EFI_ERROR(uefi_call_wrapper(fh->Read, 3, fh, size, buf))) {
		FreePool(buf);
		buf = NULL;
	}
	uefi_call_wrapper(fh->Close, 1, fh);
	return buf;
}

static BOOLEAN exists(CHAR16 *name)
{
	UINTN size;
	VOID *buf = read_file(name, &size);
	if (buf)
		FreePool(buf);
	return buf != NULL;
}

static EFI_STATUS enroll(CHAR16 *var, EFI_GUID *guid, CHAR16 *file, UINT32 extra_attrs)
{
	UINTN size;
	EFI_STATUS s;
	VOID *buf = read_file(file, &size);

	Print(L"  %s <- %s: ", var, file);
	if (!buf) {
		Print(L"MISSING\n");
		return EFI_NOT_FOUND;
	}
	s = uefi_call_wrapper(RT->SetVariable, 5, var, guid, AUTH_ATTRS | extra_attrs, size, buf);
	FreePool(buf);
	Print(EFI_ERROR(s) ? L"FAILED: %r\n" : L"ok\n", s);
	return s;
}

static VOID finish(void)
{
	BOOLEAN fw_ui = (get_u64(L"OsIndicationsSupported") & EFI_OS_INDICATIONS_BOOT_TO_FW_UI) != 0;

	Print(L"\n");
	if (fw_ui)
		Print(L"  f  reboot into firmware setup\n");
	Print(L"  r  reboot\n  s  shut down\n  q  quit to the firmware boot menu\n");
	for (;;) {
		CHAR16 c = get_key();
		if (c == L'f' && fw_ui) {
			UINT64 ind = get_u64(L"OsIndications") | EFI_OS_INDICATIONS_BOOT_TO_FW_UI;
			uefi_call_wrapper(RT->SetVariable, 5, L"OsIndications", &global_guid,
					  EFI_VARIABLE_NON_VOLATILE | EFI_VARIABLE_BOOTSERVICE_ACCESS |
					  EFI_VARIABLE_RUNTIME_ACCESS, sizeof(ind), &ind);
			uefi_call_wrapper(RT->ResetSystem, 4, EfiResetCold, EFI_SUCCESS, 0, NULL);
		}
		if (c == L'r')
			uefi_call_wrapper(RT->ResetSystem, 4, EfiResetCold, EFI_SUCCESS, 0, NULL);
		if (c == L's')
			uefi_call_wrapper(RT->ResetSystem, 4, EfiResetShutdown, EFI_SUCCESS, 0, NULL);
		if (c == L'q')
			return;
	}
}

EFI_STATUS efi_main(EFI_HANDLE image, EFI_SYSTEM_TABLE *systab)
{
	EFI_LOADED_IMAGE *li;
	BOOLEAN ms, has_ms, has_dbx;
	CHAR16 dbx[32];
	INTN setup_mode, secure_boot;

	InitializeLib(image, systab);
	uefi_call_wrapper(ST->ConIn->Reset, 2, ST->ConIn, FALSE);
	uefi_call_wrapper(BS->SetWatchdogTimer, 4, 0, 0, 0, NULL);

	Print(L"\nSecure Boot key enrollment (Kairos Alpine)\n");
	Print(L"Firmware: %s rev 0x%x\n", ST->FirmwareVendor, ST->FirmwareRevision);

	setup_mode = get_u8(L"SetupMode");
	secure_boot = get_u8(L"SecureBoot");
	if (setup_mode < 0) {
		Print(L"This firmware does not support Secure Boot, or it is switched off\n"
		      L"in the firmware setup.\n");
		finish();
		return EFI_UNSUPPORTED;
	}
	Print(L"Secure Boot: %s, Setup Mode: %s\n\n",
	      secure_boot == 1 ? L"enabled" : L"disabled", setup_mode == 1 ? L"yes" : L"no");

	if (setup_mode != 1) {
		Print(L"The firmware already has a platform key, so keys cannot be enrolled.\n"
		      L"In the firmware setup, clear the Secure Boot keys (often called\n"
		      L"'Reset to Setup Mode' or 'Delete all Secure Boot variables'),\n"
		      L"then boot this tool again.\n");
		finish();
		return EFI_SUCCESS;
	}

	if (EFI_ERROR(uefi_call_wrapper(BS->HandleProtocol, 3, image, &LoadedImageProtocol, (VOID **)&li)) ||
	    !(root = LibOpenRoot(li->DeviceHandle))) {
		Print(L"Cannot open the boot medium.\n");
		finish();
		return EFI_LOAD_ERROR;
	}
	if (!exists(L"PK.auth") || !exists(L"KEK.auth") || !exists(L"db.auth")) {
		Print(L"Key files not found in %s\n", KEYDIR);
		finish();
		return EFI_NOT_FOUND;
	}

	SPrint(dbx, sizeof(dbx), L"dbx-%s.auth", ARCH_SUFFIX);
	has_ms = exists(L"KEK-ms.auth") && exists(L"db-ms.auth");
	has_dbx = exists(dbx);
	ms = FALSE;
	if (has_ms) {
		Print(L"Also trust Microsoft's UEFI certificates? They are needed for firmware\n"
		      L"on add-in cards (GPU, network, RAID) and to boot other distributions.\n"
		      L"Without them, such cards may stop working under Secure Boot.\n");
		ms = ask(L"Trust Microsoft certificates?", TRUE);
	}

	Print(L"\nThis replaces the machine's Secure Boot keys. Afterwards only software\n"
	      L"signed by these keys%s will boot while Secure Boot is on.\n",
	      ms ? L" or Microsoft's" : L"");
	if (!ask(L"Enroll now?", FALSE)) {
		finish();
		return EFI_ABORTED;
	}

	Print(L"\n");
	if (EFI_ERROR(enroll(L"db", &secdb_guid, ms ? L"db-ms.auth" : L"db.auth", 0)))
		goto failed;
	/* A stale or rejected revocation list is not a reason to stop. */
	if (ms && has_dbx && EFI_ERROR(enroll(L"dbx", &secdb_guid, dbx, EFI_VARIABLE_APPEND_WRITE)))
		Print(L"  (continuing without the revocation list)\n");
	if (EFI_ERROR(enroll(L"KEK", &global_guid, ms ? L"KEK-ms.auth" : L"KEK.auth", 0)))
		goto failed;
	if (EFI_ERROR(enroll(L"PK", &global_guid, L"PK.auth", 0)))
		goto failed;

	Print(L"\nDone. The firmware left Setup Mode (now %s).\n"
	      L"Secure Boot is active from the next boot. Some firmware also needs it\n"
	      L"switched on in its setup.\n",
	      get_u8(L"SetupMode") == 0 ? L"User Mode" : L"still in Setup Mode?!");
	finish();
	return EFI_SUCCESS;

failed:
	Print(L"\nEnrollment stopped; the platform key was not written, so the firmware\n"
	      L"is still in Setup Mode. Running the tool again overwrites what was written.\n");
	finish();
	return EFI_ABORTED;
}
