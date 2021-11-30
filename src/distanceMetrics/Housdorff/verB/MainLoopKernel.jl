module MainLoopKernel
using CUDA, Logging,Main.CUDAGpuUtils, Main.ResultListUtils,Main.WorkQueueUtils,Main.ScanForDuplicates, Logging,StaticArrays, Main.IterationUtils, Main.ReductionUtils, Main.CUDAAtomicUtils,Main.MetaDataUtils
using Main.MetadataAnalyzePass, Main.ScanForDuplicates
export getSmallGPUForHousedorff,getBigGPUForHousedorffAfterBoolKernel,@loadDataAtTheBegOfDilatationStep,@prepareForNextDilation,@mainLoopKernel, @iterateOverWorkQueue,@mainLoop,@mainLoopKernelAllocations,@clearBeforeNextDilatation


"""
clearing data in order to enable their reuse in next iteration
clearIterResShmemLoop - given we trat res shmem as one dimensional array with 32 entries per iteration how many times we need to loop to cover all
clearIterSourceShmemLoop - the same as above but for source shmem
resShmemTotalLength, sourceShmemTotalLength - total (treating as 1 dimensional array) length of the  sourse or result shared memory
"""
macro clearBeforeNextDilatation( clearIterResShmemLoop,clearIterSourceShmemLoop,resShmemTotalLength, sourceShmemTotalLength,dataBdim)
    return esc(quote
    isMaskFull=true
    # @ifXY 1 1  CUDA.@cuprint "rrrr $(resShmem[10,10,10]) \n" #lll $(length(resShmem)) \n"
    #  for i in 1:length(resShmem) #resShmemTotalLength-1
    #     resShmem[i]=false
    #  end    
    # @iterateLinearly clearIterResShmemLoop resShmemTotalLength  resShmem[i]=false
    # @iterateLinearly clearIterSourceShmemLoop sourceShmemTotalLength  sourceShmem[i]=false
    # @iterateLinearly clearIterResShmemLoop 34*20*34  resShmem[i]=false
    # @iterateLinearly clearIterSourceShmemLoop 34*20*34  sourceShmem[i]=false

    @ifY 1 if(threadIdxX()<15) areToBeValidated[threadIdxX()]=false end 
    @ifY 2 if(threadIdxX()<7) isAnythingInPadding[threadIdxX()]=false end 
   

end)#quote
end#clearBeforeNextDilatation




"""
allocates memory in the kernel some register and shared memory  (no allocations in global memory here from kernel)
dataBdim - are dimensions of data block - each data block has just one row in the metadata ...

"""
macro mainLoopKernelAllocations(dataBdim)
    return esc(quote
#needed to manage cooperative groups functions
grid_handle = this_grid()

shmemblockData = @cuDynamicSharedMem(UInt32,(dataBdim[1], dataBdim[2] ))
# holding values of results
resShmemblockData = @cuDynamicSharedMem(UInt32,(dataBdim[1], dataBdim[2] ))
# holding data about result top, bottom, left right , anterior, posterior ,  paddings
shmemPaddings = @cuDynamicSharedMem(Bool,(  max(dataBdim[1], dataBdim[2]), max(dataBdim[1], dataBdim[2])   ,6 ))


#for storing sums for reductions
shmemSum =  @cuStaticSharedMem(UInt32,(36,14)) # we need this additional spots
#used to load from metadata information are ques to be validated 
areToBeValidated =  @cuStaticSharedMem(Bool, (14)) 
# used to mark wheather there is any true in paddings
isAnythingInPadding =  @cuStaticSharedMem(Bool, (6))
# used to accumulate counts from of fp's and fn's already covered in dilatation steps
alreadyCoveredInQueues =@cuStaticSharedMem(UInt32,(14))
 
 #coordinates of data in main array
 #we will use this to establish weather we should mark  the data block as empty or full ...
 isMaskFull= false
 #here we will store in registers data uploaded from mask for later verification wheather we should send it or not
 locArr= Int32(0)
 offsetIter = UInt8(0)
#  localOffset= UInt32(0)
 #boolean usefull in the iterating over private part of work queue 
 isAnyBiggerThanZero =  @cuStaticSharedMem(Bool,1)
 #loading data to shared memory from global about is it even or odd pass
 iterationNumberShmem =  @cuStaticSharedMem(UInt16,1)
 #current spot in tail - usefull to save where we need to access the tail to get proper block
 #shared memory variables needed to marks wheather we are already finished with  any dilatation step
 goldToBeDilatated =  @cuStaticSharedMem(Bool,1)
 segmToBeDilatated =  @cuStaticSharedMem(Bool,1)
 #true when we have more than 0 blocks to analyze in next iteration
 isEvenPass =  @cuStaticSharedMem(Bool,1) 
 #keeping information  weather we have not odd or even pass
 workCounterBiggerThan0 =  @cuStaticSharedMem(Bool,1) 
 #holding values of all work queue counters 
 workCountersInshmem= @cuStaticSharedMem(UInt16,8)

 positionInMainWorkQueaue= @cuStaticSharedMem(UInt16,1)
 @ifXY 1 1 iterationNumberShmem[1]= 0
 @ifXY 2 1 isAnyBiggerThanZero[1]= 0
 @ifXY 3 1 workCounterInshmem[1]= 0
 @ifXY 7 1 goldToBeDilatated[1]= 0
 @ifXY 8 1 segmToBeDilatated[1]= 0
 @ifXY 9 1 workCounterBiggerThan0[1]= 0
 @ifXY 19 1 isEvenPass[1]= true# set to true becouse it would be altered befor first dilatation step
 

 sync_threads()

end)#quote
end    




"""
main loop logic
"""
macro mainLoop()
    return esc(quote
    MetadataAnalyzePass.@setMEtaDataOtherPasses(locArr,offsetIter,iterationNumberShmem[1])
    sync_grid(grid_handle)
    @loadDataAtTheBegOfDilatationStep()
    sync_threads()


    @iterateOverWorkQueue($workQueaueCounter,$workQueaue
    ,shmemSumLengthMaxDiv4,begin 
        @executeDataIter(mainArrDims 
        ,dilatationArrs[shmemSum[shmemIndex*4+4]+1]
        ,referenceArrs[shmemSum[shmemIndex*4+4]+1]
        ,shmemSum[shmemIndex*4+1]#xMeta
        ,shmemSum[shmemIndex*4+2]#yMeta
        ,shmemSum[shmemIndex*4+3]#zMeta
        ,shmemSum[shmemIndex*4+4]#isGold
        ,iterationNumberShmem[1]#iterNumb
    )

    end ) 
    sync_grid(grid_handle)
    #now we should have all data needed to analyze padding ...
    @iterateOverWorkQueue($workQueaueCounter,$workQueaue
    ,shmemSumLengthMaxDiv4,begin 
    
        @executeIterPadding(mainArrDims 
        ,dilatationArrs[shmemSum[shmemIndex*4+4]+1]
        ,referenceArrs[shmemSum[shmemIndex*4+4]+1]
        ,shmemSum[shmemIndex*4+1]#xMeta
        ,shmemSum[shmemIndex*4+2]#yMeta
        ,shmemSum[shmemIndex*4+3]#zMeta
        ,shmemSum[shmemIndex*4+4]#isGold
        ,iterationNumberShmem[1]#iterNumb
        )
   sync_grid(grid_handle)


    end ) 

end) #quote
end#mainLoop



"""
iterating over elements in work queaue  in order to make it work we need  to 
    know how many elements are in the work queue - we need workQueaueCounter
    workQueaue - matrix with work queue data  
    goldToBeDilatated, segmToBeDilatated - shared memory values needed to establish weather we finished dilatations in given pass
    shmemSum will be used to store loaded data from workqueue 
    shmemSumLengthMaxDiv4 - number indicating linear length of shmemSum but reduced such that it will be divisible by 4
    ex - actions invoked on the data block when its xMeta,yMeta,zMeta and is gold pass informations are already known
    """
macro iterateOverWorkQueue(workQueaueCounter,workQueaue
    ,shmemSumLengthMaxDiv4,ex )
   return esc(quote
    #first part we load data from work queue to shmem sum 
    # we will treat shmemSum as 1 dimensional array and write data from work queue
    #mod 1 - xMeta, mod 2 - uMeta, mod 3 - zMeta mod 4 - isGoldPass
    #first we need to  establish how many items in work queue will be analyzed by this block 
    numbOfDataBlockPerThreadBlock = cld(workQueaueCounter[1],gridDimX() )

    #we need to stuck all of the blocks data into shared memory 4 entries for each block
    @unroll for outerIter in 0: fld((numbOfDataBlockPerThreadBlock*4),shmemSumLengthMaxDiv4)
        # workQuueueLinearIndexOffset = ((((numbOfDataBlockPerThreadBlock)*4 ))*(blockIdxX()-1))+ (outerIter*shmemSumLengthMaxDiv4)
        workQuueueLinearIndexOffset = ((((numbOfDataBlockPerThreadBlock)*4 ))*(blockIdxX()-1))+ (outerIter*shmemSumLengthMaxDiv4)
        # now we load all needed data into shared memory
        @iterateLinearly cld(shmemSumLengthMaxDiv4,blockDimX()*blockDimY()) shmemSumLengthMaxDiv4 begin
            #checking if we are in range
            if(i<=shmemSumLengthMaxDiv4 )

                if( ((outerIter*shmemSumLengthMaxDiv4)+i)<=((numbOfDataBlockPerThreadBlock*4)) && (workQuueueLinearIndexOffset +i)<=(workQueaueCounter[1]*4)  )
                    shmemSum[i] = workQueaue[(workQuueueLinearIndexOffset +i)]
                else
                    shmemSum[i] =0      
                end
            end
            
        end
        sync_threads()
    #at this point we had pushed into shared memory as much data as we can fit so we need to start using it         
    #second part proper iteration by definition no rounding needed here 
    #also we do not make here any attempt of parallelization as this will be done inside the expression we just provide actual metadata for dilatation step
        for shmemIndex in 0:(fld(shmemSumLengthMaxDiv4,4)-1)
                if( ((shmemIndex+1)*4 <=shmemSumLengthMaxDiv4 ) && shmemSum[shmemIndex*4+1]>0  ) #shmemSum[shmemIndex*4+1]>0
                # checking is there any point in futher dilatations of this block
                if((isGold==1 && goldToBeDilatated[1]) || (isGold==0 && segmToBeDilatated[1]) )
                    #finally all ready for dilatation step to be executed on this particular block

            
                        $ex # left just for debugging purposes
                end    
            end#if in range
        end# main functional loop for dilatation and validation  
    end#outer for 
    end)#quote 
end    


"""
main kernel managing 
"""
macro mainLoopKernel()
  return esc(quote


    @mainLoopKernelAllocations(dataBdim)

    @clearBeforeNextDilatation(clearIterResShmemLoop,clearIterSourceShmemLoop,resShmemTotalLength, sourceShmemTotalLength,dataBdim)    
    
    MetadataAnalyzePass.@analyzeMetadataFirstPass()
    
    @loadDataAtTheBegOfDilatationStep()

    # sync_grid(grid_handle)   
   #we check first wheather next dilatation step should be done or not we also establish some shared memory variables to know wheather both passes should continue or just one
    # checking weather we already finished so we need to check    
    # - is amount of results related to gold mask dilatations is equal to false positives or given percent of them
    # - is amount of results related to other  mask dilatations is equal to false negatives or given percent of them
    # - is amount of workQueue that we will want to analyze now is bigger than 0 
    # while((goldToBeDilatated[1] || segmToBeDilatated[1]) && workCounterBiggerThan0[1])
    #    @mainLoop()
    # end#while we did not yet finished
    #this will basically give the main result 
    globalIterationNumb[1]=iterationNumberShmem[1]     
end)#quote

end





"""
after dilatation prepare
"""
macro prepareForNextDilation()
    return esc(quote
    #we update metadata and prepare work queue
    setMEtaDataOtherPasses()
    #we clear  and add negation to !isOddPassShmem becouse we want to set the previously updated counter to 0 
    @clearBeforeNextDilatation( clearIterResShmemLoop,clearIterSourceShmemLoop,resShmemTotalLength, sourceShmemTotalLength,dataBdim)

    @loadDataAtTheBegOfDilatationStep()
end)#quote
end    #prepareForNextDilation



        
"""
loads data at the begining of each dilatation step
    we need to set some variables in shared memory ro initial values
    fp, fn  
"""
macro loadDataAtTheBegOfDilatationStep(  )

    return esc(quote
    #so we know that becouse of sync grid we will have evrywhere the same  iterationNumberShmem and positionInMainWorkQueaue
    
    @ifXY 1 1 iterationNumberShmem[1]+=1
    #@ifXY 2 2 positionInMainWorkQueaue[1]=0 

    @ifXY 2 1 begin
        workCounterInshmem[1]= workQueaueCounter[1] 
        workCounterBiggerThan0[1]= (workCounterInshmem[1]>0)
                    end 
    #we do corection for robustness so we can ignore some of the most distant points - this will reduce the influence of outliers                
    @ifXY 3 1 goldToBeDilatated[1]=(globalCurrentFpCount[1] <= ceil(fp[1]*robustnessPercent))
    @ifXY 4 1 segmToBeDilatated[1]=(globalCurrentFnCount[1] <= ceil(fn[1]*robustnessPercent))
        end)#quote


    # #so we know that becouse of sync grid we will have evrywhere the same  iterationNumberShmem and positionInMainWorkQueaue
    
    # @ifXY 1 1 iterationNumberShmem[1]+=1
    # #@ifXY 2 2 positionInMainWorkQueaue[1]=0 


    # #we do corection for robustness so we can ignore some of the most distant points - this will reduce the influence of outliers                
    # @ifXY 3 1 goldToBeDilatated[1]=(globalCurrentFpCount[1] <= ceil(fp[1]*robustnessPercent))
    # @ifXY 4 1 segmToBeDilatated[1]=(globalCurrentFnCount[1] <= ceil(fn[1]*robustnessPercent))
    # #we just negate  so every dilatation pass it would be altered
    # @ifXY 5 1 isEvenPass[1]= !isEvenPass[1]
    
    # #managing work queue counters
    # @ifXY 1 2  workCountersInshmem[1]= workQueueEEEcounter[1] 
    # @ifXY 2 2  workCountersInshmem[2]= workQueueEOEcounter[1] 
    # @ifXY 3 4  workCountersInshmem[3]= workQueueEEOcounter[1] 
    # @ifXY 4 2  workCountersInshmem[4]= workQueueOEEcounter[1] 

    # @ifXY 5 2  workCountersInshmem[5]= workQueueOOEcounter[1] 
    # @ifXY 6 2  workCountersInshmem[6]= workQueueEOOcounter[1] 
    # @ifXY 2 1  workCountersInshmem[7]= workQueueOEOcounter[1] 
    # @ifXY 2 1  workCountersInshmem[8]= workQueueOOOcounter[1] 
    
    # sync_warp()                
    # @ifXY 1 2 workCounterBiggerThan0[1]= ((workQueueOOOcounter[1] +workQueueOEOcounter[1]+workQueueEOOcounter[1] +workQueueOOEcounter[1] +workQueueOEEcounter[1] +workQueueEEEcounter[1] +workQueueEOEcounter[1]+workQueueEEOcounter[1])>0)



# end)#quote
end


"""
allocates memory for small GPU Arrays
"""
function getSmallGPUForHousedorff()
    globalFpResOffsetCounter= CUDA.zeros(UInt32,1)
    globalFnResOffsetCounter= CUDA.zeros(UInt32,1)
    workQueaueCounter= CUDA.zeros(UInt32,1)
    globalIterationNumber = CUDA.zeros(UInt32,1)
    globalCurrentFnCount= CUDA.zeros(UInt32,1)
    globalCurrentFpCount= CUDA.zeros(UInt32,1)
    globalIterationNumb= CUDA.zeros(UInt32,1)

return (globalFpResOffsetCounter,globalFnResOffsetCounter,workQueaueCounter,globalIterationNumber,globalCurrentFnCount,globalCurrentFpCount,globalIterationNumb )
end    

# """
# allocate memory for bigger arrays 
# """
# function getBigGPUForHousedorff()


# end 


"""
allocate after prepare bool kernel had finished execution
return metaData,reducedGoldA,reducedSegmA,reducedGoldB,reducedSegmB,resList,workQueueEEE
,workQueueEEEcounter,workQueueEEO,workQueueEEOcounter
,workQueueEOE,workQueueEOEcounter,workQueueOEE,workQueueOEEcounter
,workQueueOOE,workQueueOOEcounter,workQueueEOO,workQueueEOOcounter
,workQueueOEO,workQueueOEOcounter,workQueueOOO,workQueueOOOcounter
"""
function getBigGPUForHousedorffAfterBoolKernel(metaData,minxRes,maxxRes,minyRes,maxyRes,minzRes,maxzRes,fn,fp,reducedGoldA,reducedSegmA,dataBdim)
    ###we return only subset of boolean arrays that we are intrested in 
    # println( "zzz fp[1] $(fp[1])  fn[1] $(fn[1]) \n")
    resList = allocateResultLists(fp[1],fn[1])
    ###we need to return subset of metadata that we are intrested in 
    goldArr= reducedGoldA[minxRes[1]*dataBdim[1]:maxxRes[1]*dataBdim[1],minyRes[1]*dataBdim[2]:maxyRes[1]*dataBdim[2],minzRes[1]:maxzRes[1]]
    segmArr = reducedSegmA[minxRes[1]*dataBdim[1]:maxxRes[1]*dataBdim[1],minyRes[1]*dataBdim[2]:maxyRes[1]*dataBdim[2],minzRes[1]:maxzRes[1]]
    newMeta = metaData[minxRes[1]:maxxRes[1],minyRes[1]:maxyRes[1],minzRes[1]:maxzRes[1]   ]
    workQueue,workQueueCounter= WorkQueueUtils.allocateWorkQueue( max(length(newMeta),1) )
    metaSize = size(newMeta)
    #here we need to define data structure that will hold all data about paddings
    # it will be composed of 32x32 blocks of UInt8 where first 6 bits will represent paddings 
    # number of such blocks will be the same as innersingleDataBlockPass
    paddingStore = CUDA.zeros(UInt8, metaSize[1],metaSize[2],metaSize[3],32,32)
    
    
    return(newMeta
            ,goldArr  ,segmArr ,paddingStore

            ,resList,workQueue,workQueueCounter
    )
end 




end#MainLoopKernel



# """
# analyzing private part of work queue
# """
# macro privateWorkQueueAnalysis()
#     return esc(quote
 
#     loadOwnedWorkQueueIntoShmem(mainWorkQueue,mainQuesCounter,toIterWorkQueueShmem,positionInMainWorkQueaue ,numberOfThreadBlocks,tailParts)
#     #at this point if we have anything in the private part of the  work queue we will have it in toIterWorkQueueShmem, in case  we will find some 0 inside it means that queue is exhousted and we need to loo into tail
#     @unroll for i in UInt16(1):32# most outer loop is responsible for z dimension
#         if(toIterWorkQueueShmem[i,1]>0)
#             #we need to check also wheather given dilatation step is already finished - for example it is possible that it do not make sense to dilatate gold mask but still we need dilate other
#             if( (goldToBeDilatated[1]&&toIterWorkQueueShmem[i,4]==1) || (segmToBeDilatated[1]&&toIterWorkQueueShmem[i,4]==0)  )    
#                 @innersingleDataBlockPass(toIterWorkQueueShmem[i,4]==1,toIterWorkQueueShmem[i,1],toIterWorkQueueShmem[i,2] ,toIterWorkQueueShmem[i,3] )
#             end
#             sync_threads()
#         else    #at this point we got some 0 in the toIterWorkQueueShmem 
#             @ifXY 1 1  isAnyBiggerThanZero[]=false
#             sync_threads()
#         end#if    
#     end#for    
# end)#quote
# end    


# """
# analyzing tail part of work queue
# """
# macro analyzeTail()
#     return esc(quote

#     #below we access tail of working queue in a way that will be atomic
#     @ifXY 1 1 toIterWorkQueueShmem[1]= mainWorkQueueArr[isOddPassShmem[]+1,currentTailPosition[1]]
#     sync_threads()
#     #we need to check also wheather given dilatation step is already finished - for example it is possible that it do not make sense to dilatate gold mask but still we need dilate other
#     if( (goldToBeDilatated[1]&&toIterWorkQueueShmem[1,4]==1) || (segmToBeDilatated[1]&&toIterWorkQueueShmem[1,4]==0)  )    
#         @innersingleDataBlockPass(toIterWorkQueueShmem[1,4]==1,toIterWorkQueueShmem[1,1],toIterWorkQueueShmem[1,2] ,toIterWorkQueueShmem[1,3] )
#     end
#     loadDataNeededForTailAnalysisToShmem(currentTailPosition,tailCounter )
#     sync_threads()
# end) #quote
# end
