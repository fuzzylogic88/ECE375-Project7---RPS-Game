;***********************************************************
;*					ECE370 - Lab 7
;*
;*			Author: Daniel Green, Graham Glazner
;*					Date: 2/27/2026
;*
;***********************************************************

;***********************************************************
;*	Internal Register Definitions and Constants
;***********************************************************
.def	mpr = r16				; Multipurpose register
.def	zero = r6
.def	stateReg = r7			; interrupt flag

.def	TimerTickReg = r8
.def	ElapsedTime = r9

.def	waitcnt = r17			; Wait Loop Counter
.def	ilcnt = r18				; Inner Loop Counter
.def	olcnt = r19				; Outer Loop Counter
.equ	WTime = 15				; 150ms debounce delay


.equ	RightEngineDir = 4
.equ	LeftEngineDir = 7
.equ	MovFwd = (1<<RightEngineDir|1<<LeftEngineDir)

; Control buttons (PORTD):
.equ	GestureCycleRHBtn = 4
.equ	CycleGestureLHBtn = 5
.equ	StartBtn = 7

; COUNTDOWN TIMER PARAMS:
.equ	TimerCountownDurationSeconds = 6



;***********************************************************
;*	Start of Code Segment
;***********************************************************
.cseg

;***********************************************************
;* Interrupt Vectors
;***********************************************************

.org $0000		; Beginning of IVs
rjmp INIT		; Reset interrupt

.org $0002		; INT0,pd7
rjmp GAMESTATECHG

.org $0004		; INT1,pd4
rjmp CYCLEGESTURERH

.org $0008		; INT3,pd5
rjmp CYCLEGESTURELH

.org OVF1addr	; Timer counter 1 overflow
rjmp TIMERTICK


.org	$0056	; End of Interrupt Vectors

;***********************************************************
;*	Program Initialization
;***********************************************************
INIT:

		; Initialize Stack Pointer
		ldi		mpr, low(RAMEND)
		out		SPL, mpr		; Load SPL with low byte of RAMEND
		ldi		mpr, high(RAMEND)
		out		SPH, mpr		; Load SPH with high byte of RAMEND
    
		; Initialize Port B for output
		ldi mpr, $FF			; includes OC1A/OC1B
		out DDRB, mpr
		ldi mpr, $00
		out PORTB, mpr

		; Initialize Port D for input
		ldi		mpr, $00		; set as input
		out		DDRD, mpr		
		ldi		mpr, $FF		; Initialize Port D Data Register
		out		PORTD, mpr		; so all Port D inputs are Tri-State

		; Initialize LCD Display
		rcall LCDInit
		rcall LCDBacklightOn
		rcall LCDClr

		clr zero

		rcall USART_INIT

		; Configure External Interrupts, if needed
		; Set the Interrupt Sense Control to falling edge
		ldi mpr, 0b1000_1010 ;int3, int1, int0 => 0b10
		sts EICRA, mpr

		; Configure the External Interrupt Mask
		ldi mpr, (1<<INT0)|(1<<INT1)|(1<<INT3)
		out EIMSK, mpr

		; Configure 16-bit Timer/Counter 1A and 1B
		; set compare output mode (COM) and wave generation mode (WGM) for both timers
		;
		; Project 7: normal mode (WGM all 0), clk_freq/1024 prescaler (CSN2->CSN0, 101) => 64us per tick
		ldi mpr, (0<<COM1A1) | (0<<COM1A0) | (0<<COM1B1) | (0<<COM1B0) | (0<<WGM11) | (0<<WGM10)
		sts TCCR1A, mpr	


		; timer configuration for initial/load value (reaching 65535 for T1):
		; 150ms per tick, 10 ticks per 1.5 seconds, 4 * 10 ticks per 6
		ldi mpr, low(63192) 
		ldi r17, high(63192)
		sts TCNT1H, r17
		sts	TCNT1L, mpr

		; enable timer 1 overflow interrupt
		ldi mpr, (1<<TOIE1)
		sts TIMSK1, mpr

		ldi mpr, (0<<WGM13) | (0<<WGM12) | (1<<CS12) | (0<<CS11) | (1<<CS10)
		sts TCCR1B, mpr

		; Enable global interrupts
		sei
	

;***********************************************************
;*	Main Program
;***********************************************************
MAIN:

		; Display welcome message line 1 (ID 1)
		ldi mpr, 1
		ldi r17, 0		; string occurs at offset zero
		rcall LOADSTR	; load + display string ID 1

; wait for button press for game-ready
clr stateReg
_grWaitA:
		mov mpr, stateReg
		cpi mpr, 1		
		brne _grWaitA
		ldi		waitcnt, WTime	; Wait for 150ms
		rcall	Wait	

		; clear screen of welcome message
		rcall LCDClr

		; xmit ready signal

		; display ready message (ID 4)
		ldi mpr, 4
		mov r17, zero	; string occurs at offset zero
		rcall LOADSTR	; load + display string ID 1


; wait for ready signal from other board
clr stateReg 
_grWaitB:
		mov mpr, stateReg
		cpi mpr, 2		
		brne _grWaitB

		; everyone's ready, start 6-second countdown /w LEDs

		; disp gamestart message (ID 2)
		ldi mpr, 2
		ldi r17, 0
		rcall LOADSTR

		; enable gesture cycling (none initially displayed)
		; start 6 sec (1.5sec per LED change) timer

clr TimerTickReg
testTop:
		mov mpr, ElapsedTime
		cpi mpr, 4
		brlt testTop

		; print divider to lower screen
		ldi mpr, 10
		ldi r17, 16	; string occurs at start of 2nd line
		rcall LOADSTR

		; disable gesture cycling

		; overwrite top line with divider
		ldi mpr, 10
		ldi r17, 0	; string occurs at start of 2nd line
		rcall LOADSTR

		; display opponent's choice
		rjmp	MAIN


TIMERTICK:
	push mpr
	push r17

	in r17, SREG

	inc TimerTickReg
	mov mpr, TimerTickReg
	cpi mpr, 10

	brne exitTick

	inc ElapsedTime		; 10*150ms ticks => 1.5s elapsed
	clr TimerTickReg

exitTick:
	ldi mpr, low(63192) 
	ldi r17, high(63192)
	sts TCNT1H, r17
	sts	TCNT1L, mpr

	out SREG, r17
	pop r17
	pop mpr
	reti


;***********************************************************
;*	DISPTIMER
;*	Displays timer countdown on D4->D7 LEDs (0-15)
;***********************************************************
DISPTIMER:
	push mpr
	push r18

	mov mpr, ElapsedTime
	ldi r18, 0b11110000	; we want PB4-7, the upper 4x LEDs
	or mpr, r18
	out PORTB, mpr

	pop r18
	pop mpr
	ret


GAMESTATECHG:
	push mpr

	inc stateReg

	ldi mpr, 0b0001011
	out EIFR, mpr

	pop mpr
	reti

CYCLEGESTURERH:
	push mpr

	;code here

	ldi mpr, 0b0001011
	out EIFR, mpr

	pop mpr
	reti

CYCLEGESTURELH:
	push mpr

	; code here

	ldi mpr, 0b0001011
	out EIFR, mpr

	pop mpr
	reti


USART_Init:
	push mpr
	push r17  

	; 415 = UBBRN for 2400 Baud
	ldi mpr, 0b10011111
	ldi r17, 0b00000001

	; Set baud rate
	sts UBRR1H, r17
	sts UBRR1L, mpr

	; Enable receiver and transmitter
	ldi mpr, (1<<RXEN1)|(1<<TXEN1)
	sts UCSR1B, mpr

	; Set frame format: 8data, 2stop bit
	ldi mpr, (1<<USBS1)|(3<<UCSZ10)
	sts UCSR1C, mpr

	pop r17
	pop mpr
	ret

;*******************************************************************
;*	LOADSTR
;*	Reads and displays strings stored in program memory to LCD
;*
;*  requires string ID in mpr
;*  requires string offset into LCD memspace in r17 (32bits total)
;*******************************************************************

LOADSTR:
		push mpr
		push ZL
		push ZH
		push YL
		push YH
		push r6
		push r17
		push r18

; big ol' switch case to turn ID into address and length:

		cpi mpr, 1
		brne NOT1
			ldi r18, 32						; prime with our string length
			ldi ZL, low(WELCOME_BEG<<1)		; load source address (low)	
			ldi ZH, high(WELCOME_BEG<<1)	; load source address (high)
			rjmp LOAD
NOT1:
		cpi mpr, 2
		brne NOT2
			ldi r18, 16						
			ldi ZL, low(GAMESTART_BEG<<1)
			ldi ZH, high(GAMESTART_BEG<<1)
			rjmp LOAD
NOT2:
		cpi mpr, 3
		brne NOT3
			ldi r18, 32					
			ldi ZL, low(DEBUGSTR_BEG<<1)
			ldi ZH, high(DEBUGSTR_BEG<<1)
			rjmp LOAD
NOT3:
		cpi mpr, 4
		brne NOT4
			ldi r18, 32						
			ldi ZL, low(READYSTR_BEG<<1)
			ldi ZH, high(READYSTR_BEG<<1)
			rjmp LOAD
NOT4:
		cpi mpr, 5
		brne NOT5
			ldi r18, 16						
			ldi ZL, low(YOUWIN_BEG<<1)
			ldi ZH, high(YOUWIN_BEG<<1)
			rjmp LOAD
NOT5:
		cpi mpr, 6
		brne NOT6
			ldi r18, 16						
			ldi ZL, low(YOULOSE_BEG<<1)
			ldi ZH, high(YOULOSE_BEG<<1)
			rjmp LOAD
NOT6:
		cpi mpr, 7
		brne NOT7
			ldi r18, 8						
			ldi ZL, low(ROCK_BEG<<1)
			ldi ZH, high(ROCK_BEG<<1)
			rjmp LOAD
NOT7:
		cpi mpr, 8
		brne NOT8
			ldi r18, 8					
			ldi ZL, low(PAPER_BEG<<1)
			ldi ZH, high(PAPER_BEG<<1)
			rjmp LOAD
NOT8:
		cpi mpr, 9
		brne NOT9
			ldi r18, 8					
			ldi ZL, low(SCISSOR_BEG<<1)
			ldi ZH, high(SCISSOR_BEG<<1)
			rjmp LOAD
NOT9:
		cpi mpr, 10
		brne NOLOAD							; If no ID available, just exit.
			ldi r18, 16					
			ldi ZL, low(DIVIDER_BEG<<1)
			ldi ZH, high(DIVIDER_BEG<<1)
			rjmp LOAD

LOAD:
		; Load destination addr to place the string
		mov YL, r17
		ldi YH, $01
LDLOOP:	
		lpm r17, Z+
		st	Y+, r17
		dec r18
		brne LDLOOP

		rcall LCDWrite

NOLOAD:
		pop r18
		pop r17
		pop r6
		pop YH
		pop YL
		pop ZH
		pop ZL
		pop mpr
		ret

;----------------------------------------------------------------
; Sub:	Wait
; Desc:	A wait loop that is 16 + 159975*waitcnt cycles or roughly
;		waitcnt*10ms.  Just initialize wait for the specific amount
;		of time in 10ms intervals. Here is the general eqaution
;		for the number of clock cycles in the wait loop:
;			(((((3*ilcnt)-1+4)*olcnt)-1+4)*waitcnt)-1+16
;----------------------------------------------------------------
Wait:
		push	waitcnt			; Save wait register
		push	ilcnt			; Save ilcnt register
		push	olcnt			; Save olcnt register

Loop:	ldi		olcnt, 224		; load olcnt register
OLoop:	ldi		ilcnt, 237		; load ilcnt register
ILoop:	dec		ilcnt			; decrement ilcnt
		brne	ILoop			; Continue Inner Loop
		dec		olcnt		; decrement olcnt
		brne	OLoop			; Continue Outer Loop
		dec		waitcnt		; Decrement wait
		brne	Loop			; Continue Wait loop

		pop		olcnt		; Restore olcnt register
		pop		ilcnt		; Restore ilcnt register
		pop		waitcnt		; Restore wait register
		ret				; Return from subroutine


;***********************************************************
;*	Program Memory
;***********************************************************

; ID: 1
; strlen 16
WELCOME_BEG:
.DB		"Welcome!        Please press PD7"		
WELCOME_END:

; ID: 2
; strlen 16
GAMESTART_BEG:
.DB		"Game start      "		
GAMESTART_END:

; ID: 3
; strlen 32
DEBUGSTR_BEG:
.DB		"!!!TEST!!!TEST!!!TEST!!!TEST!!!T"		
DEBUGSTR_END:

; ID: 4
; strlen 32
READYSTR_BEG:
.DB		"Ready. Waiting  for the opponent "

; ID: 5
; strlen 16
YOUWIN_BEG:
.DB		"You won!  :D    "		
YOUWIN_END:

; ID: 6
; strlen 16
YOULOSE_BEG:
.DB		"You lost. :(    "		
YOULOSE_END:

; ID: 7
; strlen 8
ROCK_BEG:
.DB		"Rock    "		
ROCK_END:

; ID: 8
; strlen 8
PAPER_BEG:
.DB		"Paper   "		
PAPER_END:

; ID: 9
; strlen 8
SCISSOR_BEG:
.DB		"Scissor "		
SCISSOR_END:

; ID: 10
; strlen 16
; WRITE ME FIRST!
DIVIDER_BEG:
.DB		"       |        "
DIVIDER_END:


;***********************************************************
;* Additional Program Includes
;***********************************************************
.include "LCDDriver.asm"
.include "m32U4def.inc" 