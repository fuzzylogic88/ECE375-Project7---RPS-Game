;***********************************************************
;*	ECE370 Lab 7: Remotely Communicated Rock Paper Scissors
;*
;*			Authors: Daniel Green, Graham Glazner
;*			Date Created: 2/27/2026
;*			Date Modified: 3/7/2026
;
;***********************************************************

;***********************************************************
;*	Internal Register Definitions and Constants
;***********************************************************

; Gestures 
; cycle between vals 1-3 (rock,paper,scissor)
.def	OppLHGestReg = r5
.def	OppRHGestReg = r6
.def	RHGestureReg = r7
.def	LHGestureReg = r8


; Time
.def	ElapsedTicks = r9
.def	RemainingTime = r10

; Receive and Transmit
.def	ReceiveReg = r11
.def	TransmitReg = r12
.def	TransmitSuccessReg = r13

.def	mpr = r16				; Multipurpose register

; Wait
.def	waitcnt = r17			; Wait Loop Counter
.def	ilcnt = r18				; Inner Loop Counter
.def	olcnt = r19				; Outer Loop Counter
.equ	WTime = 15				; 150ms debounce delay

;LED bits
.equ LED5 = 4
.equ LED6 = 5
.equ LED7 = 6
.equ LED8 = 7
.equ FourSec = (1<<LED5 | 1<<LED6 | 1<<LED7 | 1<<LED8)
.equ ThreeSec = (1<<LED5 | 1<<LED6 | 1<<LED7)
.equ TwoSec = (1<<LED5 | 1<<LED6)
.equ OneSec = (1<<LED5)

; Control buttons (PORTD):
.equ	CycleGestureRHBtn = 4
.equ	CycleGestureLHBtn = 5
.equ	StartBtn = 7

; Signals
.equ	ReadySigVal = 0x05

.equ	RockSigVal = 0x01
.equ	PaperSigVal = 0x02
.equ	ScissorSigVal = 0x03

; misc
.equ	CountTime = 4

;***********************************************************
;*	Start of Code Segment
;***********************************************************
.cseg

;***********************************************************
;* Interrupt Vectors
;***********************************************************

.org $0000		; Beginning of IVs
rjmp INIT		; Reset interrupt

.org OVF1addr	; timer counter 1 overflow
rjmp TC1OVF

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
		; 0.5sec per rollover:
		; ((65535+1-x)*256) / 8MHz = 0.5
		ldi mpr, low(49911)  
		ldi r17, high(49911)
		sts TCNT1H, r17
		sts	TCNT1L, mpr

		ldi mpr, (0<<WGM13) | (0<<WGM12) | (1<<CS12) | (0<<CS11) | (0<<CS10)
		sts TCCR1B, mpr
	
		ldi r16, (1<<TOIE1)
		sts TIMSK1, r16


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

; end of polling for button press

		rcall LCDClr
		; display ready message (ID 4)
		ldi mpr, 4
		ldi r17, 0	
		rcall LOADSTR

		; receive and transmit ready signal
		rcall USART_Transmit
		rcall USART_Receive

		; after the ready signal is exchanged, clear flags
		ldi mpr, (1<<TXC1)
		sts UCSR1A, mpr
		clr ReceiveReg

		; everyone's ready, start 6-second countdown /w LEDs

		; disp gamestart message (ID 2) and divider for RH/LH gestures
		ldi mpr, 2
		ldi r17, 0
		rcall LOADSTR

		; clear the 2nd line of LCD and write divider
		ldi mpr, 10
		ldi r17, 16
		rcall LOADSTR

		; set default gesture to rock
		ldi mpr, RockSigVal
		mov RHGestureReg, mpr
		ldi mpr, RockSigVal
		mov LHGestureReg, mpr

		; show default on lcd
		ldi mpr, 7			; ID 7 = Rock
		ldi r17, 16			
		rcall LOADSTR

		ldi mpr, 7
		ldi r17, 24
		rcall LOADSTR

		; show 4 lights to start
		ldi mpr, FourSec
		out PORTB, mpr

		clr ElapsedTicks
		
		
_gameLoopA:
		sei ; timer interupt needed

		; poll for RH changes
		in		mpr, PIND					; Read button state
		sbrc	mpr, CycleGestureRHBtn		; Mask button into mpr
		rjmp		_skipRHCycle
		rcall CYCLERHGESTURE

	_skipRHCycle:
		; poll for LH changes
		in		mpr, PIND					; Read button state
		sbrc	mpr, CycleGestureLHBtn	; Mask only start button (7) state into mpr 
		rjmp _skipLHCycle
		rcall CYCLELHGESTURE

	_skipLHCycle:
		cli ; critical section

		; display on lights time remaining
		; if time elapsed = 3, show three lights
		mov r17, ElapsedTicks	; use r17 for elapsed compares
		cpi r17, 3
		brne _checkTwo
			ldi mpr, ThreeSec
			out PORTB, mpr
			rjmp _gameLoopA
_checkTwo:
		; if time elapsed = 6, show two lights
		cpi r17, 6
		brne _checkThree
			ldi mpr, TwoSec
			out PORTB, mpr
			rjmp _gameLoopA

_checkThree:
		; if time elapsed = 9, show one light
		cpi r17, 9
		brne _checkTimeUp
			ldi mpr, OneSec
			out PORTB, mpr
			rjmp _gameLoopA
		
_checkTimeUp:
		; time up?
		mov r17, ElapsedTicks
		cpi r17, 12		; 12 = 6 sec elapsed
		brne _gameLoopA ; repeat unless time is up

		; turn off lights
		ldi mpr, 0
		out PORTB, mpr
	
; end of game loop A
	
	cli; no more interupts!
	
	; exchange gesture values
	; Gesture 1
	; load transmit register with left hand gesture
	mov TransmitReg, LHGestureReg
	rcall USART_Transmit
	rcall USART_Receive
	; process opponent's left hand gesture
	mov OppLHGestReg, ReceiveReg

	rcall USART_Restart
	ldi		waitcnt, 100	; Wait for 1 sec
	rcall	Wait

	; Gesture 2
	; load transmit register with right hand gesture
	rcall USART_Transmit
	rcall USART_Receive
	; process opponent's right hand gesture
	mov OppRHGestReg, ReceiveReg

	; display opponent's choices in correct locations
	rcall DISPOPPGESTS

; spin here
testTop2:	
		rjmp testTop2

		; start new timer for 'shoot' choice
ldi mpr, CountTime
mov RemainingTime, mpr 
clr ElapsedTicks
 ; re-enable timer interrupt
_gameLoopB:

	; poll for RH changes
			in		mpr, PIND					; Read button state
			andi	mpr, (1<<CycleGestureRHBtn)	; Mask button into mpr 
			cpi		mpr, 0						; Is it pressed?
			breq _chooseRHInternal
			jmp _skipRHChoose
	_chooseRHInternal:
			;rcall ;func to block out LH choice and show RH choice

	_skipRHChoose:
			; poll for LH changes
			in		mpr, PIND					; Read button state
			andi	mpr, (1<<CycleGestureLHBtn)	; Mask only start button (7) state into mpr 
			cpi		mpr, 0
			breq _chooseLHInternal
			jmp _skipLHChoose
	_chooseLHInternal:
			;rcall ;func to block out RH choice and show LH choice
	_skipLHChoose:

			; timer read, tick, and compare
			; !!!! CRITICAL SECTION BEGIN !!!!
			cli
			mov mpr, ElapsedTicks
			cpi mpr, 3 ; 3 ticks => 1.5sec elapsed
			brlo _noTickB	; mpr < 2, no big tick
	_doCountdownTickB:
			dec RemainingTime
			clr ElapsedTicks
	_noTickB:
			rcall DISPTIMER
			mov mpr, RemainingTime
			cpi mpr, 0	; have six seconds elapsed?
			; !!!! CRITICAL SECTION END !!!!
		brne _gameLoopB

		rjmp	MAIN

;*	!!!	End of Main !!! !!!	End of Main !!! !!!	End of Main !!! 
;***************************************************************

TC1OVF:
	push mpr
	push r17

	inc ElapsedTicks	; 0.5sec per tick, 3 ticks per 1.5

	ldi mpr, low(49911)  
	ldi r17, high(49911)
	sts TCNT1H, r17
	sts	TCNT1L, mpr

	pop r17
	pop mpr
	reti

;***********************************************************
;*	DISPTIMER
;*	Displays opponent gestures on LCD
;***********************************************************
DISPOPPGESTS:
    push mpr
    push r17

    ; Print divider to top row
    ldi mpr, 10
    ldi r17, 0
    rcall LOADSTR

    ; Opponent LH gesture
    mov mpr, OppLHGestReg
    cpi mpr, RockSigVal
    brne _notOppLHRock
        ldi mpr, 7
        jmp _oppLhCycleEnd
_notOppLHRock:
    cpi mpr, PaperSigVal
    brne _notOppLHPaper
        ldi mpr, 8
        jmp _oppLhCycleEnd
_notOppLHPaper:
    cpi mpr, ScissorSigVal
    brne _skipOppLHWrite    ; <-- separate skip label
        ldi mpr, 9
_oppLhCycleEnd:
    ldi r17, 0              ; LH string at offset 0, L1
    rcall LOADSTR
_skipOppLHWrite:

    ; Opponent RH gesture
    mov mpr, OppRHGestReg
    cpi mpr, RockSigVal
    brne _notOppRHRock
        ldi mpr, 7
        jmp _oppRhCycleEnd
_notOppRHRock:
    cpi mpr, PaperSigVal
    brne _notOppRHPaper
        ldi mpr, 8
        jmp _oppRhCycleEnd
_notOppRHPaper:
    cpi mpr, ScissorSigVal
    brne _skipOppRHWrite    ; <-- separate skip label
        ldi mpr, 9
_oppRhCycleEnd:
    ldi r17, 9              ; RH string at offset 9, L1
    rcall LOADSTR
_skipOppRHWrite:

    pop r17
    pop mpr
    ret

;***********************************************************
;*	DISPTIMER
;*	Displays timer countdown on D4->D7 LEDs
;***********************************************************
DISPTIMER:
	; read existing PB state
	mov r18, ElapsedTicks

	cpi r18, 3		; time elapsed < 3, 4 lights
	brlo _lt4
	ldi mpr, FourSec
	rjmp _tEnd
_lt4:
	cpi r18, 6		; time elapsed < 6, 3 lights
	brlo _lt3
	ldi mpr, ThreeSec
	rjmp _tEnd
_lt3:
	cpi r18, 9		; time elapsed < 9, 2 lights
	brlo _lt2
	ldi mpr, TwoSec
	rjmp _tEnd
_lt2:
	cpi r18, 12		; time elapsed < 12, 1 light
	brlo _lt1
	ldi mpr, OneSec
	rjmp _tEnd
_lt1:
	ldi mpr, $00

_tEnd:
	out PORTB, mpr
	ret

;***********************************************************
;*	CYCLERHGESTURE
;*	Selects new gesture for RIGHT hand, updates LCD
;***********************************************************
CYCLERHGESTURE:
	push mpr
	push r17

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
	mov mpr, RHGestureReg
	cpi mpr, RockSigVal		; rock?
	brne _notRHRock
		ldi mpr, 7			; ID 7
		jmp _rhCycleEnd
_notRHRock:
	cpi mpr, PaperSigVal	; paper?
	brne _notRHPaper
		ldi mpr, 8
		jmp _rhCycleEnd
_notRHPaper:
	cpi mpr, ScissorSigVal	; scissor?
	brne _rhCycleEnd
		ldi mpr, 9
		jmp _rhCycleEnd

_rhCycleEnd:
	ldi r17, 24		; RH string always offset of line 2 + 8
	rcall LOADSTR	; display selected string

	ldi		waitcnt, WTime	; Wait for 150ms
	rcall	Wait	

	pop r17
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
	ldi r17, 16		; LH string always offset of line 2
	rcall LOADSTR	; display selected string

	ldi		waitcnt, WTime	; Wait for 150ms
	rcall	Wait	

	pop r17
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

;***********************************************************
;*  USART_Restart
;*  Disables then re-enables USART receiver to flush
;*  any in-flight bytes and reset state
;***********************************************************
USART_Restart:
    ; Disable receiver
    lds     mpr, UCSR1B
    andi    mpr, ~(1<<RXEN1)    ; clear RXEN1 bit
    sts     UCSR1B, mpr

    ; Flush any leftover bytes in buffer
    rcall   USART_Flush

    ; Re-enable receiver
    lds     mpr, UCSR1B
    ori     mpr, (1<<RXEN1)     ; set RXEN1 bit
    sts     UCSR1B, mpr
    ret

;***********************************************************
;*	USART_Flush
;*	Flushes the USART receive buffer by reading and
;*	discarding all pending data in UDR1
;***********************************************************
USART_Flush:
    lds     mpr, UCSR1A         ; Load USART Control/Status Register A
    sbrs    mpr, RXC1           ; Skip next if receive buffer has data
    ret                         ; No data — buffer empty, return
    lds     mpr, UDR1           ; Read and discard the received byte
    rjmp    USART_Flush         ; Check again for more pending bytes


;***********************************************************
;*	USART_Transmit
;*	Sends a single char in TransmitReg over USART
;***********************************************************
USART_Transmit:

	; Wait for empty transmit buffer
	lds mpr, UCSR1A
	sbrs mpr, UDRE1
	rjmp USART_Transmit

	; Put data (TransmitReg) into buffer, sends the data
	sts UDR1, TransmitReg
	ret

; non-blocking ver of transmit, returns on full txmit buffer
USART_TryTx:
    clr  TransmitSuccessReg  ; assume failure
    lds  mpr, UCSR1A
    sbrs mpr, UDRE1
    ret
    sts  UDR1, TransmitReg
    ldi  mpr, 1
    mov  TransmitSuccessReg, mpr
    ret

;******************************************************************
;*	USART_Receive
;*	gets newly-arrived char from receive buffer and place into ReceiveReg
;******************************************************************
USART_Receive:
	lds mpr, UCSR1A
	sbrs mpr, RXC1
	rjmp USART_Receive
	lds ReceiveReg, UDR1	; Get data from Receive Data Buffer
	ret

USART_TryRx:
    lds  mpr, UCSR1A
    sbrs mpr, RXC1
    ret                  ; return early if no data
    lds  ReceiveReg, UDR1
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
		brne NOT10
			ldi r18, 16					
			ldi ZL, low(DIVIDER_BEG<<1)
			ldi ZH, high(DIVIDER_BEG<<1)
			rjmp LOAD
NOT10:
		cpi mpr, 11
		brne NOLOAD		; If no ID available, just exit.
			ldi r18, 16					
			ldi ZL, low(CLRLINE_BEG<<1)
			ldi ZH, high(CLRLINE_BEG<<1)
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

; ID: 11
; strlen 16
CLRLINE_BEG:
.DB		"                "
CLRLINE_END:

;***********************************************************
;* Additional Program Includes
;***********************************************************
.include "LCDDriver.asm"
.include "m32U4def.inc" 