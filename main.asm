;***********************************************************
;*	ECE370 Lab 7: Remotely Communicated Rock Paper Scissors
;*
;*			Authors: Daniel Green, Graham Glazner
;*			Date Created: 2/27/2026
;*			Date Modified: 3/10/2026
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

; for get-one-out:
.def	OppTargetHandGesture = r3	; contains gesture received from P2
.def	TargetHandGesture = r4		; contains gesture value to be shared

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
		; fall through to MAIN

;*************************************************************
;*	Main Program

MAIN:
		; Display welcome message
		ldi mpr, 1		; ID 1
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

		; transmit ready message
		ldi r17, ReadySigVal
		rcall USART_Transmit
		
		; display ready message
		ldi mpr, 4 ; ID 4
		ldi r17, 0	
		rcall LOADSTR

_readyWaitTop:
		rcall USART_Receive
		cpi	r17, ReadySigVal
		brne _readyWaitTop

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
			dec RemainingTime
			clr ElapsedTicks
	_noTickA:
			rcall DISPTIMER
			mov mpr, RemainingTime
			cpi mpr, 0	; have six seconds elapsed?
			sei
			; !!!! CRITICAL SECTION END !!!!
			brne _gameLoopA

	cli
_gameFinishedA:
	
	; Exchange gesture values
	; Load transmit register with left hand gesture and send
	mov r17, LHGestureReg	
	rcall USART_Transmit

	; Process opponent's left hand gesture
	rcall USART_Receive
	mov OppLHGestReg, r17

	; Load transmit register with right hand gesture
	mov r17, RHGestureReg
	rcall USART_Transmit

	; Process opponent's right hand gesture
	rcall USART_Receive
	mov OppRHGestReg, r17

	; display opponent's choices in correct locations
	rcall DISPOPPGESTS

	; 'get one out' part of game starts here

	; preload target gesture with rock val
	; if nobody chooses anything, result is draw
	ldi mpr, RockSigVal
	mov TargetHandGesture, mpr

	; start new timer for 'shoot' choice
	ldi mpr, CountTime
	mov RemainingTime, mpr 
	clr ElapsedTicks
	sei
_gameLoopB:
			; poll for RH changes
			in		mpr, PIND
			andi	mpr, (1<<CycleGestureRHBtn)
			cpi		mpr, 0
			breq _chooseRHInternal
			jmp _skipRHChoose
	_chooseRHInternal:
			rcall TARGETRH

	_skipRHChoose:
			; poll for LH changes
			in		mpr, PIND
			andi	mpr, (1<<CycleGestureLHBtn)
			cpi		mpr, 0
			breq _chooseLHInternal
			jmp _skipLHChoose
	_chooseLHInternal:
			rcall TARGETLH
	_skipLHChoose:

			; timer read, tick, and compare
			; !!!! CRITICAL SECTION BEGIN !!!!
			cli
			mov mpr, ElapsedTicks
			cpi mpr, 3 ; 3 ticks => 1.5sec elapsed
			brlo _noTickB	; mpr < 2, no big tick
			dec RemainingTime
			clr ElapsedTicks
	_noTickB:
			rcall DISPTIMER
			mov mpr, RemainingTime
			cpi mpr, 0	; have six seconds elapsed?
			sei
			; !!!! CRITICAL SECTION END !!!!
			brne _gameLoopB

	cli	; disable interrupts

_shareResultsTop:
	; Exchange final gesture choices
	; Load transmit register with gesture chosen
	mov r17, TargetHandGesture
	rcall USART_Transmit
	rcall USART_Receive

	; store opponent's chosen hand gesture
	mov OppTargetHandGesture, r17

	; clear top line and display gesture
	ldi mpr, 13
	ldi r17, 0
	rcall LOADSTR

	mov mpr, OppTargetHandGesture
	cpi mpr, RockSigVal		; rock?
	brne _notOppRockB
		ldi mpr, 7			; ID 7
		jmp _oppCycleEndB
_notOppRockB:
	cpi mpr, PaperSigVal	; paper?
	brne _notOppPaperB
		ldi mpr, 8
		jmp _oppCycleEndB
_notOppPaperB:
	cpi mpr, ScissorSigVal	; scissor?
	brne _oppCycleEndB
		ldi mpr, 9
		jmp _oppCycleEndB

_oppCycleEndB:
	ldi r17, 0		; opponent string @ offset 0
	rcall LOADSTR	; display selected string

	; remove divider from L2
	ldi mpr, 14
	ldi r17, 23
	rcall LOADSTR

	; start new timer for 'shoot' choice
	ldi mpr, 2
	mov RemainingTime, mpr 
	clr ElapsedTicks
	sei ; re-enable timer interrupt
_shareWaitTop:

	; !!!! CRITICAL SECTION BEGIN !!!!
			cli
			mov mpr, ElapsedTicks
			cpi mpr, 3 
			brlo _noTickC
			dec RemainingTime
			clr ElapsedTicks
	_noTickC:
			rcall DISPTIMER
			mov mpr, RemainingTime

			rcall LCDWrite ; I don't know why this is necessary,
						   ; But it won't print the opponent gesture w/o
			cpi mpr, 0	
			sei
	; !!!! CRITICAL SECTION END !!!!
			brne _shareWaitTop

	cli

	; evaluate choices to determine winners!
	; stretch goal for sprint 2: Loser has their bootloader removed
	rcall EVALGAME

	ldi mpr, CountTime
	mov RemainingTime, mpr 
	clr ElapsedTicks
	sei ; re-enable timer interrupt

_resultsWaitTop:
	; !!!! CRITICAL SECTION BEGIN !!!!
			cli
			mov mpr, ElapsedTicks
			cpi mpr, 3 
			brlo _noTickD	
			dec RemainingTime
			clr ElapsedTicks
	_noTickD:
			rcall DISPTIMER
			mov mpr, RemainingTime
			cpi mpr, 0
			sei	
	; !!!! CRITICAL SECTION END !!!!		
			brne _resultsWaitTop

	cli
	rcall LCDClr
	rjmp	MAIN

;*	!!!	End of Main !!! !!!	End of Main !!! !!!	End of Main !!! 
;*****************************************************************

;*****************************************************************
;*	EVALGAME
;*	Determines and communicates win/loss/draw condition to player
;*****************************************************************
EVALGAME:
	push mpr
	push r17
	push r18

	mov mpr, TargetHandGesture
	mov r18, OppTargetHandGesture

	; we chose rock
	cpi mpr, RockSigVal
	brne _evlNotRock 
		cpi r18, RockSigVal
		brne _evl_rNr
		jmp _evlDrawCond
_evl_rNr:
		cpi r18, PaperSigVal
		brne _evl_rNp
		jmp _evlLossCond
_evl_rNp:
		cpi r18, ScissorSigVal
		brne _evlEnd
		jmp _evlWinCond

_evlNotRock:
	; we chose paper
	cpi mpr, PaperSigVal
	brne _evlNotPaper
		cpi r18, RockSigVal
		brne _evl_pNr
		jmp _evlWinCond
_evl_pNr:
		cpi r18, PaperSigVal
		brne _evl_pNp
		jmp _evlDrawCond
_evl_pNp:
		cpi r18, ScissorSigVal
		brne _evlEnd
		jmp _evlLossCond

_evlNotPaper:

	; we chose scissor
	cpi mpr, ScissorSigVal
	brne _evlEnd
		cpi r18, RockSigVal
		brne _evl_sNr
		jmp _evlLossCond
_evl_sNr:
		cpi r18, PaperSigVal
		brne _evl_sNp
		jmp _evlWinCond
_evl_sNp:
		cpi r18, ScissorSigVal
		brne _evlEnd
		jmp _evlDrawCond

_evlWinCond:
	ldi mpr, 5								; Win
	jmp _evlPrintResult

_evlLossCond:
	ldi mpr, 6								; Lose
	jmp _evlPrintResult

_evlDrawCond:
	ldi mpr, 12								; Draw
	jmp _evlPrintResult


_evlPrintResult:
	ldi r17, 0		; RH string always offset of line 2 + 8
	rcall LOADSTR	; display selected string

_evlEnd:
	pop r18
	pop r17
	pop mpr
	ret


;*******************************************************************
;*	TARGETRH
;*	Changes player target hand/gesture for 'get one out' mode to RH
;*******************************************************************
TARGETRH:
	push mpr
	push r17

	; paste whitespace over one not chosen (our LH, offset 16)
	ldi mpr, 11
	ldi r17, 16
	rcall LOADSTR

	; refresh the gesture text of the chosen hand (we assume it's gone)
	mov mpr, RHGestureReg
	cpi mpr, RockSigVal		; rock?
	brne _notRHRockB
		ldi mpr, 7			; ID 7
		jmp _rhCycleEndB
_notRHRockB:
	cpi mpr, PaperSigVal	; paper?
	brne _notRHPaperB
		ldi mpr, 8
		jmp _rhCycleEndB
_notRHPaperB:
	cpi mpr, ScissorSigVal	; scissor?
	brne _rhCycleEndB
		ldi mpr, 9
		jmp _rhCycleEndB

_rhCycleEndB:
	ldi r17, 24		; RH string always offset of line 2 + 8
	rcall LOADSTR	; display selected string

	; update internally which gesture we've chosen to shoot
	mov TargetHandGesture, RHGestureReg

	ldi		waitcnt, WTime	; Wait for 150ms
	rcall	Wait	

	pop r17
	pop mpr
	ret


;*******************************************************************
;*	TARGETLH
;*	Changes player target hand/gesture for 'get one out' mode to LH
;*******************************************************************
TARGETLH:
	push mpr
	push r17

	; paste whitespace over one not chosen (RH, offset 9)
	ldi mpr, 11
	ldi r17, 24
	rcall LOADSTR

	; refresh target hand gesture text
	mov mpr, LHGestureReg
	cpi mpr, RockSigVal		; rock?
	brne _notLHRockB
		ldi mpr, 7			; ID 7
		jmp _lhCycleEndB
_notLHRockB:
	cpi mpr, PaperSigVal	; paper?
	brne _notLHPaperB
		ldi mpr, 8
		jmp _lhCycleEndB
_notLHPaperB:
	cpi mpr, ScissorSigVal	; scissor?
	brne _lhCycleEndB
		ldi mpr, 9
		jmp _lhCycleEndB

_lhCycleEndB:
	ldi r17, 16		; LH string always offset of line 2
	rcall LOADSTR	; display selected string

	; update internally which gesture we've chosen to shoot
	mov TargetHandGesture, LHGestureReg

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
;*	USART_Transmit
;*	Sends a single char in r17 over USART
;***********************************************************
USART_Transmit:
	push mpr
_txTop:
	; Wait for empty transmit buffer
	lds mpr, UCSR1A
	sbrs mpr, UDRE1
	rjmp _txTop

	; Put data into buffer, sends the data
	sts UDR1, r17
	pop mpr
	ret

;******************************************************************
;*	USART_Receive
;*	gets newly-arrived char from recieve buffer and place into r17
;******************************************************************
USART_Receive:
    push mpr
wait_rx:
    lds mpr, UCSR1A
    sbrs mpr, RXC1
    rjmp wait_rx

    lds r17, UDR1
    pop mpr
    ret

;***********************************************************
;*	TC1OVF
;*	Timer/Counter 1 Overflow ISR
;***********************************************************
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
;*	DISPOPPGESTS
;*	Displays opponent's selected gestures on LCD
;***********************************************************
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
	ldi r17, 8		; RH string at offset 8, L1
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
		brne NOT11		
			ldi r18, 7					
			ldi ZL, low(BLANKSPC_BEG<<1)
			ldi ZH, high(BLANKSPC_BEG<<1)
			rjmp LOAD
NOT11:
		cpi mpr, 12
		brne NOT12			
			ldi r18, 16
			ldi ZL, low(DRAWMSG_BEG<<1)
			ldi ZH, high(DRAWMSG_BEG<<1)
			rjmp LOAD
NOT12:
		cpi mpr, 13
		brne NOT13	
			ldi r18, 16
			ldi ZL, low(CLRLINE_BEG<<1)
			ldi ZH, high(CLRLINE_BEG<<1)
			rjmp LOAD
NOT13:
		cpi mpr, 14
		brne NOLOAD		; If no ID available, just exit.
			ldi r18, 1
			ldi ZL, low(CLRSPC_BEG<<1)
			ldi ZH, high(CLRSPC_BEG<<1)
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
; strlen 7, clears a hand
BLANKSPC_BEG:
.DB		"       "
BLANKSPC_END:

; ID: 12
; strlen 16
DRAWMSG_BEG:
.DB		"Draw!           "
DRAWMSG_END:

; ID: 13
; strlen 16
CLRLINE_BEG:
.DB		"                "
CLRLINE_END:

; ID: 14
; strlen 1
CLRSPC_BEG:
.DB		" "
CLRSPC_END:

;***********************************************************
;* Additional Program Includes
;***********************************************************
.include "LCDDriver.asm"
.include "m32U4def.inc" 