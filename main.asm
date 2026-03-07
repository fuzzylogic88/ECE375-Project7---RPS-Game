;***********************************************************
;*	ECE370 Lab 7: Remotely Communicated Rock Paper Scissors
;*
;*			Authors: Daniel Green, Graham Glazner
;*			Date Created: 2/27/2026
;*			Date Modified: 3/6/2026
;
;***********************************************************

;***********************************************************
;*	Internal Register Definitions and Constants
;***********************************************************
.def	mpr = r16				; Multipurpose register
.def	zero = r6

; cycle between vals 1-3 (rock,paper,scissor)
.def	RHGestureReg = r7
.def	LHGestureReg = r8

.def	ElapsedTime = r9

.def	waitcnt = r17			; Wait Loop Counter
.def	ilcnt = r18				; Inner Loop Counter
.def	olcnt = r19				; Outer Loop Counter
.equ	WTime = 15				; 150ms debounce delay

; Control buttons (PORTD):
.equ	CycleGestureRHBtn = 4
.equ	CycleGestureLHBtn = 5
.equ	StartBtn = 7

; Signals
.equ	ReadySigVal = 0x05

.equ	RockSigVal = 0x01
.equ	PaperSigVal = 0x02
.equ	ScissorSigVal = 0x03


;***********************************************************
;*	Start of Code Segment
;***********************************************************
.cseg

;***********************************************************
;* Interrupt Vectors
;***********************************************************

.org $0000		; Beginning of IVs
rjmp INIT		; Reset interrupt

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

		; Configure the External Interrupt Mask
		ldi mpr, (1<<INT0)|(1<<INT1)|(1<<INT3)
		out EIMSK, mpr

		; Configure 16-bit Timer/Counter 1A and 1B
		; set compare output mode (COM) and wave generation mode (WGM) for both timers
		;
		; Project 7: normal mode (WGM all 0), clk_freq/256 prescaler (CSN2->CSN0, 100)
		ldi mpr, (0<<COM1A1) | (0<<COM1A0) | (0<<COM1B1) | (0<<COM1B0) | (0<<WGM11) | (0<<WGM10)
		sts TCCR1A, mpr	

		; timer configuration for initial/load value
		ldi mpr, low(46875) 
		ldi r17, high(46875)
		sts TCNT1H, r17
		sts	TCNT1L, mpr

		ldi mpr, (0<<WGM13) | (0<<WGM12) | (1<<CS12) | (0<<CS11) | (0<<CS10)
		sts TCCR1B, mpr
	



;***********************************************************
;*	Main Program

MAIN:

		; Display welcome message line 1 (ID 1)
		ldi mpr, 1
		ldi r17, 0		; string occurs at offset zero
		rcall LOADSTR	; load + display string ID 1

; poll for button press to start game
_grWaitA:

		in		mpr, PIND			; Read button state
		andi	mpr, (1<<StartBtn)	; Mask only start button (7) state into mpr 
		cpi		mpr, 0				; Is it pressed?
		brne	_grWaitA			; Not pressed, jump to top of loop.

		; debounce
		ldi		waitcnt, WTime	; Wait for 150ms
		rcall	Wait	

		rcall LCDClr

		; txmit ready signal, and preserve preexisting value
		rcall USART_Receive
		mov r18, r17

		ldi r17, ReadySigVal
		rcall USART_Transmit

		; display ready message (ID 4)
		ldi mpr, 4
		mov r17, zero	
		rcall LOADSTR


		; read whatever data might've been waiting in recv buffer
		; if we've already gotten the ready signal, skip the poll
		cpi r18, ReadySigVal
		brne _readyWaitTop
		jmp _bothRdy

clr r17
_readyWaitTop:
		rcall USART_Receive
		cpi	r17, ReadySigVal
		brne _readyWaitTop

_bothRdy:
		; everyone's ready, start 6-second countdown /w LEDs
		; disp gamestart message (ID 2) and divider for RH/LH gestures
		ldi mpr, 2
		ldi r17, 0
		rcall LOADSTR

		; divider (ID 10) 
		ldi mpr, 10
		ldi r17, $16 ; start of 2nd LCD line
		rcall LOADSTR

_gameLoopTop:
	
		; poll for RH changes
		in		mpr, PIND					; Read button state
		andi	mpr, (1<<CycleGestureRHBtn)	; Mask button into mpr 
		cpi		mpr, 0						; Is it pressed?
		breq _cycleRHInternal
		jmp _skipRHCycle
_cycleRHInternal:
		rcall CYCLERHGESTURE

_skipRHCycle:
		; poll for LH changes
		in		mpr, PIND					; Read button state
		andi	mpr, (1<<CycleGestureLHBtn)	; Mask only start button (7) state into mpr 
		cpi		mpr, 0
		breq _cycleLHInternal
		jmp _skipLHCycle
_cycleLHInternal:
		rcall CYCLELHGESTURE

_skipLHCycle:
		; timer read, tick, and compare :

		rcall UPDATETIMERLEDS
		mov mpr, ElapsedTime
		cpi mpr, 6	; have six seconds elapsed?
		brne _gameLoopTop

_gameFinishedA:

		; we will have recieved P2s RH and LH choices now, grab from buffer
		; 'get one out' starts here

testTop:	
		rjmp testTop
		rjmp	MAIN

;*	!!!	End of Main !!! !!!	End of Main !!! !!!	End of Main !!! 
;***************************************************************



;***********************************************************
;*	CYCLERHGESTURE
;*	Selects new gesture for RIGHT hand, updates LCD
;***********************************************************
CYCLERHGESTURE:
	push mpr
	mov mpr, RHGestureReg
	cpi mpr, 3				; scissor / 3 ? 
	brne _rhIncrement
	ldi mpr, 1
	mov RHGestureReg, mpr	; back to rock / 1
	jmp _skipRHIncrement
_rhIncrement:
	inc RHGestureReg		; val++
_skipRHIncrement:
	; update RH displayed LCD text
	; todo: validate LH cycling works, then paste it in here

	ldi		waitcnt, WTime	; Wait for 150ms
	rcall	Wait	
	pop mpr
	ret


;***********************************************************
;*	CYCLELHGESTURE
;*	Selects new gesture for LEFT hand, updates LCD
;***********************************************************
CYCLELHGESTURE:
	push mpr
	push r17

	mov mpr, LHGestureReg
	cpi mpr, 3				; scissor / 3 ? 
	brne _lhIncrement
	ldi mpr, 1
	mov LHGestureReg, mpr	; back to rock / 1
	jmp _skipLHIncrement
_lhIncrement:
	inc LHGestureReg		; val++
_skipLHIncrement:

	; update LH displayed LCD text
	mov mpr, LHGestureReg
	cpi mpr, RockSigVal		; rock?
	brne _notLHRock
		ldi mpr, 7			; ID 7
		jmp _lhCycleEnd
_notLHRock:
	cpi mpr, PaperSigVal	; paper?
	brne _notLHPaper
		ldi mpr, 8
		jmp _lhCycleEnd
_notLHPaper:
	cpi mpr, ScissorSigVal	; scissor?
	brne _lhCycleEnd
		ldi mpr, 9
		jmp _lhCycleEnd

_lhCycleEnd:
	ldi r17, 0		; LH string always offset 0
	rcall LOADSTR	; display selected string

	ldi		waitcnt, WTime	; Wait for 150ms
	rcall	Wait	

	pop r17
	pop mpr
	ret


;***********************************************************
;*	USART_Transmit
;*	Sends a single char in r17 over USART
;***********************************************************
USART_Transmit:

	; Wait for empty transmit buffer
	lds mpr, UCSR1A
	cpi mpr, (1<<UDRE1)
	brne USART_Transmit

	; Put data (r17) into buffer, sends the data
	sts UDR1,r17
	ret


;******************************************************************
;*	USART_Receive
;*	gets newly-arrived char from recieve buffer and place into r17
;******************************************************************
USART_Receive:
	push mpr		; Save mpr
	lds r17, UDR1	; Get data from Receive Data Buffer
	pop mpr			; Restore mpr
	ret


;***********************************************************
;*	DISPTIMER
;*	Displays timer countdown on D4->D7 LEDs (0-15)
;***********************************************************
UPDATETIMERLEDS:
	push mpr
	push r18

	mov mpr, ElapsedTime
	ldi r18, 0b11110000	; we want PB4-7, the upper 4x LEDs
	or mpr, r18
	out PORTB, mpr

	pop r18
	pop mpr
	ret

;***********************************************************
;*	USART_Init
;*	Configures and enables USART functionality
;***********************************************************
USART_Init:
	push mpr
	push r17  

	; 416 = UBBRN for 2400 Baud
	ldi mpr, low(416)
	ldi mpr, high(416)

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
			ldi r18, 7						
			ldi ZL, low(ROCK_BEG<<1)
			ldi ZH, high(ROCK_BEG<<1)
			rjmp LOAD
NOT7:
		cpi mpr, 8
		brne NOT8
			ldi r18, 7					
			ldi ZL, low(PAPER_BEG<<1)
			ldi ZH, high(PAPER_BEG<<1)
			rjmp LOAD
NOT8:
		cpi mpr, 9
		brne NOT9
			ldi r18, 7				
			ldi ZL, low(SCISSOR_BEG<<1)
			ldi ZH, high(SCISSOR_BEG<<1)
			rjmp LOAD
NOT9:
		cpi mpr, 10
		brne NOLOAD		; If no ID available, just exit.
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
; strlen 7
ROCK_BEG:
.DB		"Rock   "		
ROCK_END:

; ID: 8
; strlen 7
PAPER_BEG:
.DB		"Paper  "		
PAPER_END:

; ID: 9
; strlen 7
SCISSOR_BEG:
.DB		"Scissor"		
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