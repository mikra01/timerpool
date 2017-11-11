# simple timerpool implementation in Nim
# Copyright (c) 2017 Michael Krauter
# please see the LICENSE-file for details.

import times,sequtils,deques,locks, os

## simple timerpool implementation for uncritical (event) purposes.
## The "tick" is an abstract value and depends 
## on your timebase and the environment
##
## Its useful if you need wakeup-timers for protocol implementations or you like
## to calculate/interpolate something for a given timeslot
##
## For each TimerPool object only one tickthread is spawned which handles 
## the message-queue, allocates the timerhandles and do the work on it.
## The maximum amount of timers is only constrained by your memory 
## and the given timebase. 
##
## The allocation of a new TimerHandle always block but is threadsafe.
## The maximum blocking-time relates directly to your given timebase of the pool 
## 
## There is a blocking and a nonblocking API on the TimerHandles
## which can be used simulataneously from different threads at once. 
## All actions on the TimerHandles are completely threadsafe
## and the ptrs itself could be shared around
##
## the following example demonstrates the basic use.
## For detailed api use and for multithreading examples please refer the tests  
##
## .. code-block:: nim
##    import timerpool
##
##    let
##      tpRef = timerpool.newTimerPool(10.int) # timerpool with 10ms timebase
##      timerhdl = allocTimer(tpRef)
##  
##    timerhdl.setAlarmCounter(5)  # set expiration to 50ms (timebase * 5)
##   
##    while timerhdl.getAlarmCounter() > 0: # you can poll it
##      discard                             # .. and may doing something useful here..
## 
##    timerhdl.waitForAlarm()     # or sleep till timer expired
##    timerhdl.deallocTimer()     # pushes the timer back to pool  
##    tpRef.shutdownTimerPool()   # shutdown the pool and blocks till all
##                                # timers are expired
##
##
# TODO: shrinking of the pool is not implemented yet 
#       at the moment only tested on windows10 (Intel N3540)     
#
#
# some implementation hints: 
# the TimerHandles are maintained and owned by the tickthread
# 
# instead of maintaining and handling multiple
# messages per thread there is only one message/action per thread possible (PMsg).
# The pointer to this object is stored within the thread-local var 
# "threadContext" and it's initialized by calling "initThreadContext".
# By calling newTimerPool this proc is called implicitly.
# Due to that (and to simplify the api) the allocation of a new timer
# and retrieving some pool statistics is always blocking. The maximum
# idle time is related to your timebase.
# but once allocated, all actions on the timer itself could be blocking
# or nonblocking dependend on your needs 
#

when not compileOption("threads"):
  {.error: "TimerPool requires --threads:on option.".}

type
  TimerHandle = object
    # the timer is active if alarmctr > 0 and not freed
    alarmctr : int      # countdown field
    waitLock : Lock     # lock used for the blocking-style alarm api
    waitCond : Cond     # condition associated to the waitLock
    timerFreed : bool   # true if the owner of the handle is the pool
    waitingOnLockCount : int # counts how many threads waiting on the lock. needed
                             # that no signal is lost 
    
  TimerHandleRef = ref TimerHandle  # used by the tickthread
  
  TimerHandlePtr* = ptr TimerHandle
    ## pointer type to the timerpoolhandle. 
  
  SomePtr = ptr object  # ugly solution cause Thread needs a concrete type
  TPError* = object of Exception 
    ## generic exception
type
  PoolCmd = enum requestTimer,poolStats,killPool,shrinkPool,noOp
  PoolReply = enum success,abort
  # success is the default reply; abort is always answered if the
  # pool is about to shutdown

# guard pragma not possible here because the lock and the fields
# reside within different objects
type 
  PMsg = object        # message which is passed to the tickthread
    cmd : PoolCmd
    reply : PoolReply  
    allocTimerCompleteCond  : Cond
    replyTimerHandlePtr : TimerHandlePtr
    poolStatsCompleteCond: Cond # allows waiting for the getStats
    statRunningTimers  : int    # alarmcounter > 0
    statInactiveTimers : int    # alarmcounter == 0, prev fired
    statFreedTimers : int       # hdl released back to pool

  PMsgPtr = ptr PMsg
  PMsgRef = ref PMsg
# global var which needs to be initialized with initThreadContext
# if we are not the owner of the object
var threadContext {.threadvar.}: PMsgRef
  
type
  # queue for emiting the pool commands to the workerthread
  # for low resource environments an array could be used instead
  CmdQueuePtr = ptr Deque[PmsgPtr]
  CmdQueue = Deque[PmsgPtr]
  ThreadArg = tuple[poolobjptr:SomePtr,mintimers:int]
  
type
  TimerPool = object
    timebase : int         # the timebase of the tickthread
    tickthread : Thread[ThreadArg]
    # Lock for accessing the cmd-queue and check for poolShutdownDone
    poolReqLock : Lock
    cmdQueue {.guard: poolReqLock.} : CmdQueue 
    poolShutdownDoneCond: Cond 
    spawningThreadId : int

type 
  TimerPoolPtr* = ptr TimerPool
    ## used to share among threads
  TimerPoolRef* = ref TimerPool
    ## used to shutdown 
    ## the pool by the spawning thread

# generic templates for both API and workerthread  
template atomicLoad[T](t: T ) : T =
  atomicLoadN[T](t.addr,ATOMIC_ACQ_REL) 

template atomicStore[T](t : T, t1 : T) =  
  atomicStoreN[T](t.addr,t1,ATOMIC_ACQ_REL) 

# timer_state templates
template timerRunning(timerref : TimerHandleRef) : bool =
  not atomicLoad[bool](timerref[].timerFreed) and 
    atomicLoad[int](timerref[].alarmctr) > 0

template timerDone(timerref : TimerHandleRef) : bool =
  not atomicLoad[bool](timerref[].timerFreed) and 
    atomicLoad[int](timerref[].alarmctr) == 0

template timerFreed(timerref : TimerHandleRef) : bool =
  atomicLoad[bool](timerref.timerFreed)

template threadWaiting(timerref : TimerHandleRef) : bool =
  atomicLoad[int](timerref.waitingOnLockCount) > 0

# api templates
template checkForValidThreadContext() : void = 
  if threadContext.isNil:
    raise newException(
      TPError," please call initThreadContext() before using the API ")

template checkForNil*(timerhdl : TimerHandlePtr,callingProc : string = "") : void =
  ## checks if the timerhdl is nil. if so a TPError is raised
  if timerhdl.isNil:
    raise newException(TPError,callingProc & ": timer_handle is nil ")
  
template checkForNil(stpp : TimerPoolPtr, callingProc: string = "") : void =
  if stpp.isNil:
    raise newException(TPError,callingProc & ": TimerPoolPtr is nil ")

template checkIfSpawningThread(tpptr : TimerPoolPtr) =
  if tpptr.spawningThreadId == getThreadId():
    raise newException(TPError, " execution of this proc prohibited within the owning thread ")

template poolRef2Ptr*(stpp : TimerPoolRef) : TimerPoolPtr =
  ## convenience template to get the TimerPoolPtr from the ref
  (cast[TimerPoolPtr](stpp))

template msgRef2Ptr(pmsgref : PMsgRef ) : PMsgPtr =
  (cast[PMsgPtr](pmsgref))

template abortWhenTimerFreed(timerhdl : TimerHandlePtr, p : string) =
  if atomicLoad[bool](timerhdl.timerFreed):
    # TODO: provide better debug info which timer was freed 
    # and from which source to trackdown nasty sharing errors
    raise newException(TPError,p & "timer already freed ")

template waitOnTimerhdl(timerhdl : TimerHandlePtr) =
    # wait counter. each wait_condition is counted. this ensures
    # that the signaling side (the worker thread which calls "signal")
    # knows how many times "signal" must be called to wake up all waiting
    # threads properly (the Lock-api has no notify_all-style call at the moment)
    discard atomicInc(timerhdl.waitingOnLockCount)   
    wait(timerhdl.waitCond,timerhdl.waitLock)   
    discard atomicDec(timerhdl.waitingOnLockCount)   

template waitOnStatsComplete(stpp : TimerPoolPtr, req: PMsgRef ) =
    wait(req.poolStatsCompleteCond,stpp.poolReqLock)   

template validatePoolReply(rep : PMsgRef) =
    if rep.reply == PoolReply.abort:
      raise newException(TPError," pool is about to shutdown - request aborted ")

type
  ShutdownState = enum poolRunning,shutdownRequested,doShutdown
  # once shutdown recognised, the commandqueue isn´t processed anymore
  # but the workerloop still processes the running timers (shutdownRequested)
  # once all timers are fired, the state goes to doShutdown, all resources
  # are freed and the workerthread bails out
         
proc findFreeTimer(sptr : seq[TimerHandleRef] ) : TimerHandleRef =
  # searches for an unused timerhdl (timerFreed) 
  # nil is returned if no unused timerhdl present  
  result = nil
  
  for n in filter[TimerHandleRef](sptr, 
                  proc (x : TimerHandleRef): bool =
                  if not x.isNil:  
                    result = timerFreed(x)
                  else:
                    result = false):
    result = n          
    break


proc timerPoolWorkLoop(startupcontext : ThreadArg) {.thread.} =
  #  ThreadArg = tuple[poolobjptr:SomePtr,mintimers:int]
  # TimerPoolptr : SomePtr,minimumTimers : int
  let 
    sptr : TimerPoolPtr = cast[TimerPoolPtr](startupcontext.poolobjptr)    
    mintimers : int = startupcontext.mintimers
  var
    allTHandles : seq[TimerHandleRef] = newSeq[TimerHandleRef](0)
    runningTimersCount : int 
    freedTimersCount : int 
    inactiveTimersCount : int 
    shutdownState : ShutdownState = ShutdownState.poolRunning
    currTime : float    
    poolIdle : bool   # true if all timers freed
    
  poolIdle = false

  while true:
 
    # measure the time we need for waiting on the lock and doing the work, 
    # substract this from the given sleeping-time to get a smoothed timebase
    currTime = cpuTime()
  
    runningTimersCount = 0
    freedTimersCount = 0
    inactiveTimersCount = 0
       
    if not poolIdle:  # perform pool scan
      for i in allTHandles.low .. allTHandles.high:
        let timer = allTHandles[i]
        if not timer.isNil:  
          if timerRunning(allTHandles[i]):
            discard atomicDec(allTHandles[i].alarmctr) 
            runningTimersCount = runningTimersCount + 1
          elif timerFreed(allTHandles[i]): 
            freedTimersCount = freedTimersCount + 1
          else:
            inactiveTimersCount = inactiveTimersCount + 1
        
          if timerDone(allTHandles[i]) or timerFreed(allTHandles[i]):
            # we need also check for freed-state because the timer could
            # be freed while it's counting 
            while threadWaiting(allTHandles[i]):
              signal(allTHandles[i].waitCond)
              # we call signal for each waiting thread
    
    poolIdle = (runningTimersCount + inactiveTimersCount) == 0  
    # TODO: perform sleep if the pool stays for given amount of cycles idle
    # we need a new signal which must be sent every time when a new command
    # is put into the queue

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
            poolIdle = false
            var timerHandle = findFreeTimer(allTHandles)
            if timerHandle.isNil:
              # initialise new handle
              # as stated here by araq https://forum.nim-lang.org/t/104
              # allocShared is not needed (also see TimerPool ctor)
              # and the gc does the job for us
              timerhandle = cast[TimerHandleRef]
                              (new TimerHandle)
              initLock(timerHandle.waitLock)
              initCond(timerHandle.waitCond)
              allTHandles.add(timerHandle)
            # recycled handle found 
            timerHandle.alarmctr = 0
            timerHandle.timerFreed = false
            timerHandle.waitingOnLockCount = 0
            # send response back to calling thread
            pmsgptr.reply = PoolReply.success
            pmsgptr.replyTimerHandlePtr = cast[TimerHandlePtr]
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
            if freedTimersCount > minTimers:
              discard
            # todo: implement shrink 
            #(removal of some freed handles if exceed watermark) 
          else:
            discard

    else:  
      if shutdownState == ShutdownState.shutdownRequested:
        # probe if all timers are done. if so, enter state doShutdown
        # do not consume command queue any more
        if runningTimersCount == 0:
          shutdownState = ShutdownState.doShutdown
      
      elif shutdownState == ShutdownState.doShutdown:
        for i in allTHandles.low .. allTHandles.high:
          let timer = allTHandles[i]
          if not timer.isNil:  
            deinitLock(allTHandles[i].waitLock)
            deinitCond(allTHandles[i].waitCond)
  
        allTHandles.delete(allTHandles.low,allTHandles.high)
        allTHandles = nil
        signal(sptr.poolShutdownDoneCond)
        break # exit worker loop

    # adjust timebase and sleep / msused is in millisecs 
    let msused : int =  cast[int]((cpuTime() - currTime)*1_000) 
    if sptr.timebase > msused:
      sleep( sptr.timebase - msused )

  
proc createTimerPool( tbase : int) : ref TimerPool =
  result = new TimerPool
  result.timebase = tbase
  result.spawningThreadId = getThreadId()  
  initLock(result.poolReqLock)
  initCond(result.poolShutdownDoneCond)
  withLock(result.poolReqLock):
    # strange lock needed because of the compiler check
    result.cmdQueue = deques.initDeque[PMsgPtr](8)

# public api
type
  Tickval* = range[1..int.high]
  MinTimerval* = range[1..int.high]
    ## integer type used to initialise the timerpool and to set the 
    ## timeout of the timer

proc initThreadvar() : void =   
  threadContext =  new PMsg
  initCond(threadContext.allocTimerCompleteCond)
  initCond(threadContext.poolStatsCompleteCond)
  threadContext.cmd = PoolCmd.noOp  

proc deinitThreadvar() : void = 
  deinitCond(threadContext.allocTimerCompleteCond)
  deinitCond(threadContext.poolStatsCompleteCond)  
  
proc initThreadContext*(tpptr : TimerPoolPtr) : void {.raises: [TPError].} =
  ## to be called explicit if the pool-accessing thread is not the
  ## owner of the timerpool (initialises threadvar globs)
  ##
  ## raises a TPError if called within the spawning thread
  checkIfSpawningThread(tpptr)
  initThreadvar()
  
proc newTimerPool*(tbase_ms : Tickval = 100, mintimers : MinTimerval = 10) : ref TimerPool {.gcsafe.} =
  ## creator proc.   
  ## The tickval is of milliseconds and 
  ## the default timebase is 100 milliseconds
  ## the default of the mintimers parameter is 10 (shrink_pool leave this
  ## minimum amount of timers within the pool)
  result = createTimerPool(tbase_ms)
  initThreadvar()
  createThread(result.tickthread,timerPoolWorkLoop,(cast[SomePtr](result),cast[int](mintimers)))

proc deinitThreadContext*(tpptr : TimerPoolPtr) : void {.gcsafe , raises: [TPError].} =
  ## call this proc if the pool-accessing thread should be
  ## detached from the timerpool (cleanup threadvar globs)
  ##
  ## call this proc only if the current thread is not owner of the
  ## timerpool. if not a TPError is raised
  checkIfSpawningThread(tpptr)
  deinitThreadvar()
  
proc shutdownTimerPool*(tpref :  TimerPoolRef ) : void {.gcsafe.} =
  ## shuts down the timerpool (graceful) and frees 
  ## all resources (timerHandles and the pool itself)
  ##
  ## this call blocks till all timers are fired
  ## also only the spawning/owning thread is allowed to shutdown the pool
  ## this is guarded/ensured by the ref-parameter type within the public ctor
  threadContext.cmd = PoolCmd.killPool
  withLock(tpref.poolReqLock):
    tpref.cmdqueue.addLast(cast[PMsgPtr](threadContext))  
    wait(tpref.poolShutdownDoneCond,tpref.poolReqLock)
    while tpref.cmdqueue.len > 0:
      # flush queue and inform possible waiting threads
      let pendingcmds = tpref.cmdqueue.popLast()    
      pendingcmds.reply = PoolReply.abort
      
      case pendingcmds.cmd
     
      of requestTimer:
        signal(pendingcmds.allocTimerCompleteCond)
      of poolStats:
        signal(pendingcmds.poolStatsCompleteCond)
      else:
        discard
  
  deinitCond(tpref.poolShutdownDoneCond)
  deinitLock(tpref.poolReqLock)
  deinitThreadvar() 

proc allocTimer*(tpptr : TimerPoolPtr) : TimerHandlePtr {.gcsafe , raises: [TPError].} =
  ## returns a timerhandle. the timer is always of type:oneshot but could
  ## also act as a continous one. in this case the caller needs to reset the
  ## alarm to the needed value. This threadsafe call blocks till the request 
  ## was handled by the pool-tick-thread
  ##
  ## before calling (if the pool was not spawned by the calling thread)
  ## initThreadContext() should be called
  ##
  ## raises TPError if the pointer parameter is nil and/or the threadContext
  ## was not initialised with initThreadContext
  checkForNil(tpptr,"allocTimer")
  checkForValidThreadContext()
  threadContext.cmd = PoolCmd.requestTimer  
  withLock(tpptr.poolReqLock):
    tpptr.cmdqueue.addLast(msgRef2Ptr(threadContext))    
    wait(threadContext.allocTimerCompleteCond,tpptr.poolReqLock)
  
  validatePoolReply(threadContext) 
  result = threadContext.replyTimerHandlePtr

proc allocTimer*(tpptr : TimerPoolRef) : TimerHandlePtr {.gcsafe ,inline, raises: [TPError].} =
  return allocTimer(poolRef2Ptr(tpptr))
  
proc deallocTimer*(timerhdl : TimerHandlePtr) : void {.gcsafe , raises: [TPError].} =
  ## the timer handle is pushed back to the pool. 
  ## once freed it is not handled by the timerscan any more and its recycled for later use
  ##
  ## this proc could be called from multiple threads simultaneously.
  ## if one ore more threads are waiting on the timers signal all threads 
  ## gets informed. This call is part of the nonblocking api
  ## 
  ## raises TPError if the pointer parameter is nil
  checkForNil(timerhdl,"deallocTimer")
  abortWhenTimerFreed(timerhdl,"deallocTimer")
  atomicStore[bool](timerhdl.timerFreed,true)

proc setAlarmCounter*(timerhdl : TimerHandlePtr , value : Tickval ) : void {.gcsafe , raises: [TPError].} =
  ## sets the timers countdown alarm-value to the given one.
  ## reset the counter after it´s fired to obtain a continous timer
  ## 
  ## this call is threadsafe and part of the nonblocking-api
  ##
  ## raises TPError if the pointer parameter is nil or the timer is freed
  checkForNil(timerhdl,"setAlarmCounter")
  abortWhenTimerFreed(timerhdl,"setAlarmCounter")
  atomicStore[int](timerhdl.alarmctr,value)  

proc getAlarmCounter*(timerhdl : TimerHandlePtr ) : int {.gcsafe , raises: [TPError].} =
  ## returns the current value of the alarmcounter
  ## could be used for a polling-style-waiting_for_timer_fired
  ##
  ## this call is threadsafe and part of the nonblocking-api
  ##
  ## raises TPError if the pointer parameter is nil or the timer already freed
  checkForNil(timerhdl,"getAlarmCounter")
  abortWhenTimerFreed(timerhdl,"getAlarmCounter")
  result = atomicLoad[int](timerhdl.alarmctr)

proc waitForAlarm*(timerhdl : TimerHandlePtr) : void {.gcsafe , raises: [TPError].} =
  ## blocking wait till the alarmcounter is decremented to 0
  ## 
  ## threadsafe impl and could be called by multiple threads simultaniously
  ##
  ## raises TPError if the pointer parameter is nil or the timer already freed
  checkForNil(timerhdl,"waitForAlarm")
  abortWhenTimerFreed(timerhdl,"waitForAlarm")
  withLock(timerhdl.waitLock):
    waitOnTimerhdl(timerhdl)
   
type
  PoolStats* {.gcsafe.} = tuple[runningCount:int, freedCount:int,
                                inactiveCount:int]
    ## container type returned by waitForGetStats. the sum of 
    ## runningCount,freedCount and inactiveCount is the total amount
    ## of timerhandles within the pool

proc waitForGetStats*(tpptr : TimerPoolPtr) : PoolStats {.gcsafe , raises: [TPError].} =
  ## fetches some pool statistics for debugging purposes
  ##
  ## raises TPError if the pointer parameter is nil or the threadContext
  ## was not initialized with initThreadContext
  checkForNil(tpptr,"waitForGetStats")
  checkForValidThreadContext()
  threadContext.cmd = PoolCmd.poolStats
  withLock(tpptr.poolReqLock):
    tpptr.cmdqueue.addLast(msgRef2Ptr(threadContext))  
    waitOnStatsComplete(tpptr,threadContext)
  
  validatePoolReply(threadContext)  
  result.runningCount = threadContext.statRunningTimers
  result.freedCount = threadContext.statFreedTimers
  result.inactiveCount = threadContext.statInactiveTimers


