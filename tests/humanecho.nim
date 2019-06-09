import terminal,strutils,random,os,threadpool
import ../timerpool

# funstuff: human type simulator
# simple showcase to demonstrate the timerpool usage

# we split the string into words and calculate random
# waits on each char
# each word is written to the console in different threads
# (for each word one thread and timer)
# at different timeslots (this lead to simulated type errors)

type 
  WordIndex = tuple[startidx:int,length:int]
  # each word inside the string is indexed with start and length
    
proc getWordIdx(p : string) : seq[WordIndex] = 
  result = newSeq[WordIndex](0)
  var subresult : WordIndex = (0,p.high)
  
  for i in 0 .. p.high:
    if isSpaceAscii(p[i])  or i == p.high: 
      # iterate over the string and check word boundary or end of string
      subresult.length = i
      result.add(subresult)
      subresult = (i+1,p.high)

type 
  StringPtr = ptr string
  WordChunk = tuple[payload : StringPtr,idxrange : WordIndex, 
                    timer: TimerHandlePtr]

proc outputWord(dest : File, output:WordChunk, 
                rwaits:seq[int], timeslot : int = 0) : void {.thread.} =
  ## output worker method. 
  var ctr = 0
  if timeslot > 0:
    output.timer.setAlarmCounter(timeslot)
    output.timer.waitForAlarm # wait on our timeslot
  for i in output.idxrange.startidx .. output.idxrange.length:
    output.timer.setAlarmCounter(rwaits[ctr])
    stdout.write(output.payload[i])
    output.timer.waitForAlarm
    inc(ctr)
  output.timer.deallocTimer()
   
proc absTypingTime(val:seq[int]) : int =
  ## get sum of rand (absolute typing time per word)
  result = 0
  for x in val:
    result = result + x

proc generateAbsRandomWaitsPerChar(val:string, metadata: WordIndex) : seq[int] =
  result = newSeq[int](0)
  for idx in metadata.startidx..metadata.length:
    result.add(rand(range[10.int..20.int])) # TODO parameterize the behaviour

proc echoTyped*(dest : File, payload : string) =
  ## funny string output with possible errors
  let tp = newTimerPool(10)
  var
    pl : string = payload  
    words :seq[WordIndex] = getWordIdx(pl)
    sptr : StringPtr = pl.addr
    offset = 0.int

  for word in words:
    let waitsperchar = generateAbsRandomWaitsPerChar(pl,word)
    var chunk = (sptr,word,tp.allocTimer)
    spawn outputWord(dest,chunk,waitsperchar,offset)
    offset = offset + (absTypingTime(waitsperchar) - rand(range[1.int..25.int]))
    # simulate type error by substracting something from the timeslot-offset

  sync()   
  tp.shutdownTimerPool()

when isMainModule:
  stdout.echoTyped("Hello Nim....")
  stdout.echoTyped("   follow the white rabbit  ") 
  stdout.echoTyped("and dont forget to take the red pill .. :-)")
  
  
    
