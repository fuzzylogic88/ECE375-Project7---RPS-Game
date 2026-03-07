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

; cycle between vals 1-3 (rock,paper,scissor)
.def	OppLHGestReg = r5
.def	OppRHGestReg = r6
.def	RHGestureReg = r7 
.def	LHGestureReg = r8

; Time
.def	ElapsedTicks = r9
.def	RemainingTime = r10

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
		ldi r17, 0	
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

		; clear the 2nd line of LCD and write divider
		ldi mpr, 10
		ldi r17, 16
		rcall LOADSTR

		; clear gesture regs
		clr RHGestureReg
		clr LHGestureReg

ldi mpr, CountTime
mov RemainingTime, mpr 
clr ElapsedTicks
sei
_gameLoopA:
	
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

			; timer read, tick, and compare
			; !!!! CRITICAL SECTION BEGIN !!!!
			cli
			mov mpr, ElapsedTicks
			cpi mpr, 3 ; 3 ticks => 1.5sec elapsed
			brlo _noTickA	; mpr < 2, no big tick
	_doCountdownTickA:
			dec RemainingTime
			clr ElapsedTicks
	_noTickA:
			rcall DISPTIMER
			mov mpr, RemainingTime
			cpi mpr, 0	; have six seconds elapsed?
			sei
			; !!!! CRITICAL SECTION END !!!!
			brne _gameLoopA

_gameFinishedA:
cli

; !@#!@# TEST! !@#!@#! REMOVE BEFORE FLIGHT !@#!@#!@
rcall LCDClr

clr r1		; write OK????
clr r2		; sum of total rx/tx
clr r3		; count of recv'd items
clr r4		; count of written items
clr OppRHGestReg
clr OppLHGestReg


_ldLoopTop:

	clr r17
	clr mpr

	mov mpr, r3				; read count of recv'd items

	ldi XL, $00
	ldi XH, $01
	rcall Bin2ASCII
	rcall LCDWrite
	mov mpr, r3

	rcall USART_Receive		; get item if available
	cpi r17, 0				; nothing available, try to write
	breq _tryWrite

	cpi mpr, 0				; first item? (lh)
	breq _lhValRead
	cpi mpr, 1				; 2nd item (rh)
	breq _rhValRead			
	cpi mpr, 2				; done reading, try to write
	breq _tryWrite
_lhValRead:
	mov OppLHGestReg, r17
	jmp _doneValRead

_rhValRead:
	mov OppRHGestReg, r17
	jmp _doneValRead

_doneValRead:
	inc r3
	jmp _ldLoopCheck

_tryWrite:
	mov mpr, r4	; get count of total sent items

	ldi XL, $10
	ldi XH, $01
	rcall Bin2ASCII
	rcall LCDWrite
	mov mpr, r4

	cpi mpr, 0	; sent nothing? send LH
	breq _txLhGest
	jmp _txRhGest
_txLhGest:
		mov r17, LHGestureReg
		jmp _doValWrite
_txRhGest:
		cpi mpr, 1				; sent lh item?
		brne _ldLoopCheck		; val is 2, jump out
		mov r17, RHGestureReg	; send RH gest.
		jmp _doValWrite



_doValWrite:

	rcall USART_TryTx
	mov mpr, r1

	ldi XL, $18
	ldi XH, $01
	rcall Bin2ASCII
	rcall LCDWrite
	mov mpr, r1

	cpi mpr, 1				; are we back here because it failed??
	breq _ldLoopCheck		; yes: jump to bottom

	inc r4					; no: increment count of written items
	jmp _ldLoopCheck

_ldLoopCheck:
	; add both, and cp against 4 to see if all done
	mov r2, r4
	add r2, r3
	mov mpr, r2

	ldi XL, $08
	ldi XH, $01
	rcall Bin2ASCII
	rcall LCDWrite
	mov mpr, r2
	cpi	mpr, 4

	breq _doneRxTx
	jmp _ldLoopTop

_doneRxTx:


; !@#!@# TEST! !@#!@#! REMOVE BEFORE FLIGHT !@#!@#!@
rcall LCDClr

	mov mpr, OppLHGestReg
	ldi XL, $00
	ldi XH, $01
	rcall Bin2ASCII
	rcall LCDWrite

	mov mpr, OppRHGestReg
	ldi XL, $10
	ldi XH, $01
	rcall Bin2ASCII
	rcall LCDWrite
	; spin here
	testTop1:	
			rjmp testTop1

		; we will have recieved P2s RH and LH choices now, and sent ours
		; 'get one out' starts here

		; display opponent choices in correct locations
		rcall DISPOPPGESTS

; spin here
testTop2:	
		rjmp testTop2

		; start new timer for 'shoot' choice
ldi mpr, CountTime
mov RemainingTime, mpr 
clr ElapsedTicks
sei ; re-enable timer interrupt
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
			sei
			; !!!! CRITICAL SECTION END !!!!
		brne _gameLoopB

		rjmp	MAIN

;*	!!!	End of Main !!! !!!	End of Main !!! !!!	End of Main !!! 
;***************************************************************

USART_Flush:
	lds mpr, UCSR1A
	cpi mpr, (1<<UDRE1)
	brne _stopFlush
	lds mpr, UDR1
	rjmp USART_Flush
_stopFlush:
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

; non-blocking ver of transmit, returns on full txmit buffer
USART_TryTx:
	clr r1	; clear success flag

	; Wait for empty transmit buffer
	lds mpr, UCSR1A
	cpi mpr, (1<<UDRE1)
	brne _txmit
	inc r1
	ret
_txmit:
	; Put data (r17) into buffer, sends the data
	sts UDR1,r17
	ret

;******************************************************************
;*	USART_Receive
;*	gets newly-arrived char from recieve buffer and place into r17
;******************************************************************
USART_Receive:
	push mpr		; Save mpr
	clr r17
	lds r17, UDR1	; Get data from Receive Data Buffer
	pop mpr			; Restore mpr
	ret



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

DISPOPPGESTS:
	push mpr
	push r17
	push r18

	; Print divider to top row
	ldi mpr, 10
	ldi r17, 0
	rcall LOADSTR

	; read out opponent's LH gesture first
	mov mpr, OppLHGestReg
	cpi mpr, RockSigVal		; rock?
	brne _notOppLHRock
		ldi mpr, 7			; ID 7
		jmp _oppLhCycleEnd
_notOppLHRock:
	cpi mpr, PaperSigVal	; paper?
	brne _notOppLHPaper
		ldi mpr, 8
		jmp _oppLhCycleEnd
_notOppLHPaper:
	cpi mpr, ScissorSigVal	; scissor?
	brne _skipOppWrite
		ldi mpr, 9
		jmp _oppLhCycleEnd


_oppLhCycleEnd:
	ldi r17, 0		; RH string at offset 0 of L1
	rcall LOADSTR

	; now same with RH gesture
	mov mpr, OppRHGestReg
	cpi mpr, RockSigVal		; rock?
	brne _notOppRHRock
		ldi mpr, 7			; ID 7
		jmp _oppRhCycleEnd
_notOppRHRock:
	cpi mpr, PaperSigVal	; paper?
	brne _notOppRHPaper
		ldi mpr, 8
		jmp _oppRhCycleEnd
_notOppRHPaper:
	cpi mpr, ScissorSigVal	; scissor?
	brne _skipOppWrite
		ldi mpr, 9
		jmp _oppRhCycleEnd
_oppRhCycleEnd:
	ldi r17, 9		; RH string at offset 9, L1
	rcall LOADSTR

_skipOppWrite:
	pop r18
	pop r17
	pop mpr
	ret

;***********************************************************
;*	DISPTIMER
;*	Displays timer countdown on D4->D7 LEDs
;***********************************************************
DISPTIMER:
	push mpr
	push r18

	; read existing PB state
	mov r18, RemainingTime

	cpi r18, 4
	brne _lt4
	ldi mpr, FourSec
	jmp _tEnd
_lt4:
	cpi r18, 3
	brne _lt3
	ldi mpr, ThreeSec
	jmp _tEnd
_lt3:
	cpi r18, 2
	brne _lt2
	ldi mpr, TwoSec
	jmp _tEnd
_lt2:
	cpi r18, 1
	brne _lt1
	ldi mpr, OneSec
	jmp _tEnd
_lt1:
	cpi r18, 0
	brne _noChg
	ldi mpr, 0
	jmp _tEnd

_tEnd:
	out PORTB, mpr
_noChg:
	pop r18
	pop mpr
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