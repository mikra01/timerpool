# tested on
# Nim Compiler Version 0.17.3 (2017-10-20) [Windows: amd64]
# Copyright (c) 2006-2017 by Andreas Rumpf
# git hash: 1a0032eb6875c58ec1b64e9d98240e43cef04b91
# active boot switches: -d:release

import times,sequtils,deques,locks, os

## simple timerpool implementation for uncritical (event) purposes.
## The "tick" is an abstract value and depends 
## on your timebase and the environment
##
## Its useful if you need wakeup-timers for protocol impl. or you like
## to calculate/interpolate only for a given timeslot and then bail out
## 
## please look at the tests for some simplified examples
##
## For each TimerPool object only one tickthread is spawned which handles 
## the message-queue, allocates the timerhandles and do the work on it.
## The maximum amount of timers is only constrained by your memory #
## and the given timebase. 
##
## The allocation of a new TPoolHandle always block but is threadsafe.
## The maximum blocking-time relates directly to your given timebase of the pool 
## 
## There is a blocking and a nonblocking API on the TPoolHandles depentend
## on your needs. All actions on the TPoolHandles are completely threadsafe
## and the ptrs itself could be shared among multiple threads
## 
# TODO: shrinking of the pool is not implemented yet 
#       more environments needed to checkout. at the moment only
#       tested on windows10 (Intel N3540)     
#
#
# some implementation hints: 
# the TPoolHandles are maintained and owned by the tickthread
# 
# instead of maintaining and handling multiple
# messages per thread there is only one message/action per thread possible (PMsg).
# The pointer to this object is stored within the thread-local var 
# "threadContext" and it's initialized by calling "initThreadContext()".
# By calling newTimerPool this proc is called implicitly.
# Due to that (and to simplify the api) the allocation of a new timer
# and retrieving some pool statistics is always blocking. The maximum
# idle time is related to your timebase.
# but once allocated, all actions on the timer itself could be blocking
# or nonblocking dependend on the your needs 
#

when not compileOption("threads"):
  {.error: "TimerPool requires --threads:on option.".}

type
  TPoolHandle* = object
    # the timer is active if alarmctr > 0 and not freed
    alarmctr : int      # countdown field
    waitLock : Lock     # lock used for the blocking-style alarm api
    waitCond : Cond     # condition associated to the waitLock
    timerFreed : bool   # set to true to push timer back to pool
    waitingOnLockCount : int # counts how many threads waiting on the lock. needed
                             # that no signal is lost 

  TPoolHandleRef = ref TPoolHandle  # used by the tickthread
  TPoolHandlePtr* = ptr TPoolHandle
  SomePtr = ptr object  # ugly solution cause Thread needs a concrete type
  STPError* = object of Exception # generic exception

type
  PoolCmd = enum requestTimer,poolStats,killPool,shrinkPool,noOp
  PoolReply = enum success,abort
  ## success is the default reply; abort is always answered if the
  ## pool is about to shutdown

# guard pragma not possible here because the lock and the fields
# reside within different objects
type 
  PMsg = object        # message which is passed to the tickthread
    cmd : PoolCmd
    reply : PoolReply  
    allocTimerCompleteCond  : Cond
    replyTPoolHandlePtr : TPoolHandlePtr
    poolStatsCompleteCond: Cond # allows waiting for the getStats
    statRunningTimers  : int    # alarmcounter > 0
    statInactiveTimers : int    # alarmcounter == 0, prev fired
    statFreedTimers : int       # hdl released back to pool

  PMsgPtr = ptr PMsg
  PMsgRef = ref PMsg
# global var which needs to be initialized with initThreadContext()
var threadContext* {.threadvar.}: PMsgRef
  
type
  # queue for emiting the pool commands to the workerthread
  # for low resource environments an array could be used instead
  CmdQueuePtr = ptr Deque[PmsgPtr]
  CmdQueue = Deque[PmsgPtr]
  
type
  TimerPool = object
    timebase : int         # the timebase of the tickthread
    tickthread : Thread[SomePtr]
    # Lock for accessing the cmd-queue and check for poolShutdownDone
    poolReqLock : Lock
    cmdQueue {.guard: poolReqLock.} : CmdQueue 
    poolShutdownDoneCond: Cond 

type
  TimerPoolPtr* = ptr TimerPool
  TimerPoolRef* = ref TimerPool
  
# generic templates for both API and workerthread  
template atomicLoad[T](t: T ) : T =
  atomicLoadN[T](t.addr,ATOMIC_ACQ_REL) 

template atomicStore[T](t : T, t1 : T) =  
  atomicStoreN[T](t.addr,t1,ATOMIC_ACQ_REL) 

# timer_state templates
template timerRunning(timerref : TPoolHandleRef) : bool =
  not atomicLoad[bool](timerref[].timerFreed) and 
    atomicLoad[int](timerref[].alarmctr) > 0

template timerDone(timerref : TPoolHandleRef) : bool =
  not atomicLoad[bool](timerref[].timerFreed) and 
    atomicLoad[int](timerref[].alarmctr) == 0

template timerFreed(timerref : TPoolHandleRef) : bool =
  atomicLoad[bool](timerref.timerFreed)

template threadWaiting(timerref : TPoolHandleRef) : bool =
  atomicLoad[int](timerref.waitingOnLockCount) > 0

# api templates
template checkForValidThreadContext() : void = 
  if threadContext.isNil:
    raise newException(
      STPError," please call initThreadContext() before using the API ")

template checkForNil(timerhdl : TPoolHandlePtr,p : string) : void =
  if timerhdl.isNil:
    raise newException(STPError,p & ": timer_handle is nil ")

template checkForNil(stpp : TimerPoolPtr, p: string) : void =
  if stpp.isNil:
    raise newException(STPError,p & ": TimerPoolPtr is nil ")

template poolRef2Ptr*(stpp : TimerPoolRef) : TimerPoolPtr =
  (cast[TimerPoolPtr](stpp))
## convenience template to get the TimerPoolPtr from the ref

template msgRef2Ptr(pmsgref : PMsgRef ) : PMsgPtr =
  (cast[PMsgPtr](pmsgref))

template abortWhenTimerFreed(timerhdl : TPoolHandlePtr, p : string) =
  if atomicLoad[bool](timerhdl.timerFreed):
    # TODO: provide better debug info which timer was freed 
    # and from which source to trackdown nasty sharing errors
    raise newException(STPError,p & "timer already freed ")

template waitOnTimerhdl(timerhdl : TPoolHandlePtr) =
    # semaphore
    discard atomicInc(timerhdl.waitingOnLockCount)   
    wait(timerhdl.waitCond,timerhdl.waitLock)   
    discard atomicDec(timerhdl.waitingOnLockCount)   

template waitOnStatsComplete(stpp : TimerPoolPtr, req: PMsgRef ) =
    wait(req.poolStatsCompleteCond,stpp.poolReqLock)   

type
  ShutdownState = enum poolRunning,shutdownRequested,doShutdown
  # once shutdown recognised, the commandqueue isn´t processed anymore
  # but the workerloop still processes the running timers (shutdownRequested)
  # once all timers are fired, the state goes to doShutdown, all resources
  # are freed and the workerthread bails out
         
proc findFreeTimer(sptr : seq[TPoolHandleRef] ) : TPoolHandleRef =
  # searches for an unused timerhdl (timerFreed) 
  # nil is returned if no unused timerhdl present  
  result = nil
  
  for n in filter[TPoolHandleRef](sptr, 
                  proc (x : TPoolHandleRef): bool =
                  if not x.isNil:  
                    result = timerFreed(x)
                  else:
                    result = false):
    result = n          
    break


proc softTimerWorkLoop(TimerPoolptr : SomePtr) {.thread.} =
  let 
    sptr : TimerPoolPtr = cast[TimerPoolPtr](TimerPoolptr)    
  var
    allTHandles : seq[TPoolHandleRef] = newSeq[TPoolHandleRef](50)
    runningTimersCount : int 
    freedTimersCount : int 
    inactiveTimersCount : int 
    shutdownState : ShutdownState = ShutdownState.poolRunning
    currTime : float    

  while true:
    runningTimersCount = 0
    freedTimersCount = 0
    inactiveTimersCount = 0
    # measure the time we need for waiting on the lock and doing the work, 
    # substract this from the given sleeping-time to get a smoothed timebase
    currTime = cpuTime()

    # handle the conditions for existing timers
    # if the alarm-val is 0 its signaled via the condition
    # but only if someone is waiting on it
    for i in allTHandles.low .. allTHandles.high:
      let timer = allTHandles[i]
      if not timer.isNil:  
        if timerRunning(allTHandles[i]):
          discard atomicDec(allTHandles[i].alarmctr) 
          # no compile error without discard!
          runningTimersCount = runningTimersCount + 1
        elif timerFreed(allTHandles[i]): 
          freedTimersCount = freedTimersCount + 1
        else:
          inactiveTimersCount = inactiveTimersCount + 1
        
        if timerDone(allTHandles[i]) or timerFreed(allTHandles[i]):
          if threadWaiting(allTHandles[i]):
            # we need also check for freed-state because the timer could
            # be freed while it's counting 
            signal(allTHandles[i].waitCond)
    
    if shutdownState == ShutdownState.poolRunning:
      # read out the queue. for each run we consume the entire queue

      withLock(sptr.poolReqLock):
        # only ptr-type allowed to prevent the thread local gc
        # playing with it
        let cmdqueueptr : CmdQueuePtr = cast[CmdQueuePtr]
                                         (sptr.cmdQueue.addr)

        while cmdqueueptr[].len > 0:      
          let pmsgptr : PMsgPtr = cmdqueueptr[].popLast
          let activeCommand = pmsgptr.cmd
           
          case activeCommand
   
          of requestTimer:
            var timerHandle = findFreeTimer(allTHandles)
            if timerHandle.isNil:
              # initialise new handle
              # as stated here https://forum.nim-lang.org/t/104
              # allocShared is not needed (also see TimerPool construction)
              timerhandle = cast[TPoolHandleRef]
                              (new TPoolHandle)
              initLock(timerHandle.waitLock)
              initCond(timerHandle.waitCond)
              allTHandles.add(timerHandle)
            # recycled handle found 
            timerHandle.alarmctr = 0
            timerHandle.timerFreed = false
            timerHandle.waitingOnLockCount = 0
            # send response back to calling thread
            pmsgptr.reply = PoolReply.success
            pmsgptr.replyTPoolHandlePtr = cast[TPoolHandlePtr]
                                              (timerHandle)
            signal(pmsgptr.allocTimerCompleteCond)
         
          of poolStats:
            pmsgptr.statRunningTimers = runningTimersCount
            pmsgptr.statFreedTimers = freedTimersCount
            pmsgptr.statInactiveTimers = inactiveTimersCount
            signal(pmsgptr.poolStatsCompleteCond)
           
          of killPool:
            shutdownState = ShutdownState.shutdownRequested
          of shrinkPool:
            discard                   
            # todo: implement shrink 
            #(removal of some freed handles if exceed watermark) 
          else:
            discard

    else:  
      if shutdownState == ShutdownState.shutdownRequested:
        # probe if all timers are done. if so, enter state doShutdown
        if runningTimersCount == 0:
          shutdownState = ShutdownState.doShutdown
      
      elif shutdownState == ShutdownState.doShutdown:
        for i in allTHandles.low .. allTHandles.high:
          let timer = allTHandles[i]
          if not timer.isNil:  
            deinitLock(allTHandles[i].waitLock)
            deinitCond(allTHandles[i].waitCond)
            # deallocShared(timer)
        allTHandles.delete(allTHandles.low,allTHandles.high)
        allTHandles = nil
        signal(sptr.poolShutdownDoneCond)
        break # exit worker loop

    # adjust timebase and sleep / msused is in millisecs 
    let msused : int =  cast[int]((cpuTime() - currTime)*1_000) 
    if sptr.timebase > msused:
      sleep( sptr.timebase - msused )

  
proc createTimerPool( tbase : int ) : ref TimerPool =
  result = new TimerPool
  result.timebase = tbase  
  initLock(result.poolReqLock)
  initCond(result.poolShutdownDoneCond)
  withLock(result.poolReqLock):
    # strange lock needed because of the compiler check
    result.cmdQueue = deques.initDeque[PMsgPtr](8)

# public api
type
  Tickval* = range[1..int.high]

proc initThreadContext*() : void =
  ## needs to be called explicit if the pool-accessing thread is not the
  ## owner of the timerpool (initialises threadvar globs)
  threadContext =  new PMsg
  initCond(threadContext.allocTimerCompleteCond)
  initCond(threadContext.poolStatsCompleteCond)
  threadContext.cmd = PoolCmd.noOp  
  
proc newTimerPool*(tbase : Tickval = 100) : ref TimerPool {.gcsafe.} =
  ## creates a new TimerPool. 
  ## The tickval is of milliseconds and 
  ## the default timebase is 100 milliseconds
  result = createTimerPool(tbase)
  initThreadContext()
  createThread(result.tickthread,softTimerWorkLoop,cast[SomePtr](result))

proc deinitThreadContext*() : void {.gcsafe.} =
  ## needs to be called explicit if the pool-accessing thread should be
  ## detached from the timerpool (cleanup threadvar globs)
  deinitCond(threadContext.allocTimerCompleteCond)
  deinitCond(threadContext.poolStatsCompleteCond)  
    
proc shutdownTimerPool*(stpp :  TimerPoolRef ) : void {.gcsafe.} =
  ## shuts down the timerpool (graceful) and frees 
  ## all resources (timerHandles and the pool itself)
  ##
  ## this call blocks till all timers are fired
  threadContext.cmd = PoolCmd.killPool
  withLock(stpp.poolReqLock):
    stpp.cmdqueue.addLast(cast[PMsgPtr](threadContext))  
    wait(stpp.poolShutdownDoneCond,stpp.poolReqLock)
    while stpp.cmdqueue.len > 0:
      # flush queue and inform possible waiting threads
      let pendingcmds = stpp.cmdqueue.popLast()    
      pendingcmds.reply = PoolReply.abort
      signal(pendingcmds.allocTimerCompleteCond)
      signal(pendingcmds.poolStatsCompleteCond)
  
  deinitCond(stpp.poolShutdownDoneCond)
  deinitLock(stpp.poolReqLock)
  deinitThreadContext() 

proc allocTimer*(stpp : TimerPoolPtr) : TPoolHandlePtr {.gcsafe.} =
  ## returns a timerhandle. the timer is always of type: oneshot but could
  ## also act as a continous one. in this case the caller needs to reset the
  ## alarm to the needed value. This threadsafe call blocks till the request 
  ## was handled by the pool-tick-thread
  ##
  ## before calling (if the pool was not spawned by the calling thread)
  ## initThreadContext() should be called
  checkForNil(stpp,"allocTimer")
  checkForValidThreadContext()
  threadContext.cmd = PoolCmd.requestTimer  
  withLock(stpp.poolReqLock):
    stpp.cmdqueue.addLast(msgRef2Ptr(threadContext))    
    wait(threadContext.allocTimerCompleteCond,stpp.poolReqLock)
    
  result = threadContext.replyTPoolHandlePtr

proc deallocTimer*(timerhdl : TPoolHandlePtr) : void {.gcsafe.} =
  ## the timer handle is pushed back to the pool. 
  ## once freed it is not handled any more and its recycled for later use
  ##
  ## this proc could be called from multiple threads simultaneously.
  ## if a thread is waiting on the timers signal the thread gets informed
  ## about this event
  checkForNil(timerhdl,"deallocTimer")
  abortWhenTimerFreed(timerhdl,"deallocTimer")
  atomicStore[bool](timerhdl.timerFreed,true)

proc setAlarmCounter*(timerhdl : TPoolHandlePtr , value : Tickval ) : void {.gcsafe.} =
  ## sets the timers countdown alarm-value to the given one.
  ## reset the counter after it´s fired to obtain a continous timer
  ## 
  ## this call is threadsafe
  checkForNil(timerhdl,"setAlarmCounter")
  abortWhenTimerFreed(timerhdl,"setAlarmCounter")
  atomicStore[int](timerhdl.alarmctr,value)  

proc getAlarmCounter*(timerhdl : TPoolHandlePtr ) : int {.gcsafe.} =
  ## returns the current value of the alarmcounter
  ## could be used for a polling-style-waiting_for_timer_fired
  ##
  ## this call is threadsafe
  checkForNil(timerhdl,"getAlarmCounter")
  abortWhenTimerFreed(timerhdl,"getAlarmCounter")
  result = atomicLoad[int](timerhdl.alarmctr)

proc waitForAlarm*(timerhdl : TPoolHandlePtr) : void {.gcsafe.} =
  ## blocking wait till the alarmcounter is decremented to 0
  ## 
  ## threadsafe impl and could be called by multiple threads simultaniously
  checkForNil(timerhdl,"waitForAlarm")
  abortWhenTimerFreed(timerhdl,"waitForAlarm")
  withLock(timerhdl.waitLock):
    waitOnTimerhdl(timerhdl)
   
type
  PoolStats* {.gcsafe.} = tuple[runningCount:int, freedCount:int,
                                inactiveCount:int] 

proc waitForGetStats*(stpp : TimerPoolPtr) : PoolStats {.gcsafe.} =
  ## fetches some pool statistics for debugging purposes
  checkForNil(stpp,"waitForGetStats")
  checkForValidThreadContext()
  threadContext.cmd = PoolCmd.poolStats
  withLock(stpp.poolReqLock):
    stpp.cmdqueue.addLast(msgRef2Ptr(threadContext))  
    waitOnStatsComplete(stpp,threadContext)
    
  result.runningCount = threadContext.statRunningTimers
  result.freedCount = threadContext.statFreedTimers
  result.inactiveCount = threadContext.statInactiveTimers


