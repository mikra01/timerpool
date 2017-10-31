import timerpool
import times,threadpool,os
import unittest

suite "test_general_features":
    setup:
      var
        stpRef = timerpool.newTimerPool(10.int)
        timerhdls = newSeq[TimerHandlePtr](5)
      for i in timerhdls.low .. timerhdls.high:
        timerhdls[i] = poolRef2Ptr(stpRef).allocTimer()
    
    teardown:
      stpRef.shutdownTimerPool()    

    # test the timerstates
    test "test_timerstate":
 
      # set all timers fire after 5 ticks
      for i in timerhdls.low .. timerhdls.high:
        timerhdls[i].setAlarmCounter(5.int) # run for about 50ms
      var statsBefore : PoolStats = (cast[TimerPoolPtr](stpRef))
                                      .waitForGetStats
      sleep(70) # wait till timer fired
      var statsAfter  = poolRef2Ptr(stpRef).waitForGetStats
      for i in timerhdls.low .. timerhdls.high:
        timerhdls[i].deallocTimer()
      var statsFinal  = poolRef2Ptr(stpRef).waitForGetStats
      check:
        statsBefore.runningCount == 5
        statsBefore.freedCount == 0
        statsBefore.inactiveCount == 0
        statsAfter.runningCount == 0
        statsAfter.freedCount == 0
        statsAfter.inactiveCount == 5
        statsFinal.runningCount == 0
        statsFinal.freedCount == 5
        statsFinal.inactiveCount == 0

    test "timerExceptions":
        for i in timerhdls.low .. timerhdls.high:
          timerhdls[i].deallocTimer()
        # call on freed timer should thow an exception
        expect(timerpool.TPError):
          timerhdls[timerhdls.low].setAlarmCounter(50)
        expect(timerpool.TPError):
          timerhdls[timerhdls.low].deallocTimer()
        expect(timerpool.TPError):
          discard timerhdls[timerhdls.low].getAlarmCounter()
        expect(timerpool.TPError):
          timerhdls[timerhdls.low].waitForAlarm()

suite "test_threading":
    setup:
      var
        stpRef= timerpool.newTimerPool(10.int)
        timerhdls = newSeq[TimerHandlePtr](5)
      for i in timerhdls.low .. timerhdls.high:
        timerhdls[i] = (poolRef2Ptr(stpRef)).allocTimer()
      
    teardown:
      stpRef.shutdownTimerPool()     

    test "one_timer_200_childthreads":
      # worker proc per thread
      proc dosomething(timerhdl :TimerHandlePtr) : int =
                       result = 1
                       timerhdl.waitForAlarm()

      var presults = newSeq[FlowVar[int]](200)
      timerhdls[0].setAlarmCounter(10) # 200ms
 
      for i in presults.low..presults.high:
        presults[i] = spawn dosomething(timerhdls[0])
        discard stpRef.poolRef2Ptr.waitForGetStats
      timerhdls[0].waitForAlarm()
      # every thread is also waiting on it. if finished the results
      # are present
      var tresult : int = 0 
      for i in presults.low..presults.high:
        tresult = tresult + ^presults[i] 
      
      check:  
        tresult == 200
    
    test "early_wakeup":
      # multiple threads are waiting on a timer and needs to be interrupted.
      # due to that we dealloc the timer before done.
      # all threads should wakeup immediately
      proc dosomething(timerhdl :TimerHandlePtr) : int =
                       result = 1
                       timerhdl.waitForAlarm()
      var presults = newSeq[FlowVar[int]](250)
      
      timerhdls[0].setAlarmCounter(900) # 9000ms
      timerhdls[1].setAlarmCounter(50) 
  
      var ctime = cpuTime()
  
      for i in presults.low..presults.high:
        presults[i] = spawn dosomething(timerhdls[0])
      timerhdls[0].deallocTimer() # dealloc before done
      # every thread is also waiting on it. if finished the results
      # are present
      var tresult : int = 0 
      for i in presults.low..presults.high:
        tresult = tresult + ^presults[i] 
      ctime = cpuTime() - ctime  
     
      check:  
        tresult == 250
        ctime < 500
       
    test "multiple_threads_alloc":
        # multiple threads requesting a new timer from the pool
        proc dosomething(poolhdl :TimerPoolPtr) : int =
                         var timer : TimerHandlePtr = nil
                         try:
                           initThreadContext(poolhdl)
                           timer = poolhdl.allocTimer()
                           timer.setAlarmCounter(2)
                           # do something till timeout reached
                           while timer.getAlarmCounter() > 0:
                             result = result + 1  
                         except:
                           echo getCurrentExceptionMsg()
                         finally:
                             timer.deallocTimer()
                             deinitThreadContext(poolhdl)
        
        var presults = newSeq[FlowVar[int]](250)
        for i in presults.low..presults.high:
          presults[i] = spawn dosomething(poolRef2Ptr(stpRef))

        var tresult : int = 0 

        for i in presults.low..presults.high:
          tresult = tresult + ^presults[i] 
        
        # snd run        
        for i in presults.low..presults.high:
          presults[i] = spawn dosomething(poolRef2Ptr(stpRef))

        var tresult2 : int = 0 

        for i in presults.low..presults.high:
          tresult2 = tresult2 + ^presults[i] 
        
        #thrd run

        for i in presults.low..presults.high:
          presults[i] = spawn dosomething(poolRef2Ptr(stpRef))
 
        var tresult3 : int = 0 

        for i in presults.low..presults.high:
          tresult3 = tresult3 + ^presults[i] 
    