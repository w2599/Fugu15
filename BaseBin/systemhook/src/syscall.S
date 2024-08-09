.text

.align 4

.global _syscall__posix_spawn
_syscall__posix_spawn:
	MOV X16, #0xF4
	SVC 0x80
	B.CC _spawn_ret
	STP X29, X30, [SP,#-0x10]!
	MOV X29, SP
	BL _cerror
	LDP X29, X30, [SP],#0x10
_spawn_ret:
	ret

.global _syscall_issetugid
_syscall_issetugid:
	MOV X16, #0x147
	SVC 0x80
	B.CC _issetugid_ret
	STP X29, X30, [SP,#-0x10]!
	MOV X29, SP
	BL _cerror_nocancel
	LDP X29, X30, [SP],#0x10
_issetugid_ret:
	ret

.global _syscall__sysctlbyname
_syscall__sysctlbyname:
	MOV X16, #0x112
	SVC 0x80
	B.CC ___sysctlbyname_ret
	STP X29, X30, [SP,#-0x10]!
	MOV X29, SP
	BL _cerror_nocancel
	LDP X29, X30, [SP],#0x10
___sysctlbyname_ret:
	ret

.global _syscall__sysctl
_syscall__sysctl:
	MOV X16, #0xCA
	SVC 0x80
	B.CC ___sysctl_ret
	STP X29, X30, [SP,#-0x10]!
	MOV X29, SP
	BL _cerror_nocancel
	LDP X29, X30, [SP],#0x10
___sysctl_ret:
	ret