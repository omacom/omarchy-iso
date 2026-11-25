/*
 * What an NVIDIA N1x's firmware describes and Omarchy's platform detector
 * (omarchy-hw-platform) looks for: an I2C controller with the ACPI ID
 * NVDA0200, MediaTek MT8901 IP on the N1x's CPU side.
 *
 * It has no resources. On an N1x they are its registers and its interrupt;
 * here there are none, so linux-omarchy's i2c-mt65xx, which binds NVDA0200,
 * finds no register window and gives up before it reads or writes anything.
 */
DefinitionBlock ("", "SSDT", 2, "OMACOM", "N1X", 1)
{
    Scope (\_SB)
    {
        Device (I2C0)
        {
            Name (_HID, "NVDA0200")
            Name (_UID, Zero)
        }
    }
}
