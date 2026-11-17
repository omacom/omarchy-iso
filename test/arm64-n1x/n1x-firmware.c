/*
 * The two things Omarchy reads from an NVIDIA N1x's firmware, for a VM's:
 *
 *   - the SSDT compiled from nvda0200.asl, added to the firmware's ACPI tables
 *     through its own ACPI table protocol, so the kernel finds the N1x's
 *     NVDA0200 device and Omarchy's detector names the machine aarch64-n1x;
 *   - EXPOSED_DISP_FRM, the variable NVIDIA and the OEMs size the GPU's
 *     memory reservation with, as an N1x ships it, which the install shrinks
 *     (omarchy-apply-n1x-gpu-memory) and which a later boot leaves as it is.
 *
 * A UEFI driver: the firmware runs it from a PCI option ROM while it
 * enumerates PCI, before it boots anything.
 */
#include <efi.h>

#include "nvda0200.hex" /* nvda0200_aml_code[], from iasl -tc */

/* EFI_ACPI_TABLE_PROTOCOL, UEFI 2.10 section 20.1. */
static EFI_GUID acpi_table_guid = {
	0xffe06bdd, 0x6107, 0x46a6, { 0x7b, 0xb2, 0x5a, 0x9c, 0x7e, 0xc5, 0x27, 0x5c }
};
struct acpi_table_protocol {
	EFI_STATUS (EFIAPI *install)(struct acpi_table_protocol *self, VOID *table, UINTN size, UINTN *key);
	EFI_STATUS (EFIAPI *uninstall)(struct acpi_table_protocol *self, UINTN key);
};

static EFI_GUID exposed_disp_frm_guid = {
	0x4b086294, 0x0740, 0x4f71, { 0xa7, 0xb5, 0x85, 0xa3, 0x29, 0xc7, 0xec, 0x5f }
};
static UINT8 exposed_disp_frm[] = {
	0x00, 0xfa, 0x00, 0x00,	/* the reservation in MiB: 62.5 GiB */
	0x00, 0x00, 0x00, 0x20,	/* the rest of the layout NVIDIA described */
	0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00,
	0x01, 0x00, 0x00, 0x00,
	0x00,			/* set when a new size is to be applied */
};

EFI_STATUS EFIAPI efi_main(EFI_HANDLE image, EFI_SYSTEM_TABLE *system)
{
	struct acpi_table_protocol *acpi;
	UINTN key, size = 0;
	EFI_STATUS status;

	(void)image;
	status = system->BootServices->LocateProtocol(&acpi_table_guid, NULL, (VOID **)&acpi);
	if (EFI_ERROR(status))
		return status;
	status = acpi->install(acpi, nvda0200_aml_code, sizeof(nvda0200_aml_code), &key);
	if (EFI_ERROR(status))
		return status;

	/* Asked with no room for it, the firmware says whether it is there. */
	status = system->RuntimeServices->GetVariable(u"EXPOSED_DISP_FRM", &exposed_disp_frm_guid,
						      NULL, &size, NULL);
	if (status == EFI_SUCCESS || status == EFI_BUFFER_TOO_SMALL)
		return EFI_SUCCESS;
	if (status != EFI_NOT_FOUND)
		return status;
	return system->RuntimeServices->SetVariable(u"EXPOSED_DISP_FRM", &exposed_disp_frm_guid,
		EFI_VARIABLE_NON_VOLATILE | EFI_VARIABLE_BOOTSERVICE_ACCESS | EFI_VARIABLE_RUNTIME_ACCESS,
		sizeof(exposed_disp_frm), exposed_disp_frm);
}
