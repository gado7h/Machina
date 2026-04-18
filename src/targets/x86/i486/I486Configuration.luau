local I486Configuration = {}

I486Configuration.name = "x86-i486-pc"

I486Configuration.defaults = {
	EMULATION = {
		PROFILE = "x86-i486",
	},
	X86 = {
		MACHINE_PROFILE = "ibm-pc-486dx2-bios-v1",
		CPU = {
			FAMILY = "i486",
		},
		TRACE = {
			ENABLED = false,
			CPU_STATE = false,
			IRQ_ROUTING = false,
			PORT_IO = false,
			BIOS_CALLS = false,
			DISK = false,
		},
	},
}

return I486Configuration
