######### getting all together in Housedorff 

using Revise, Parameters, Logging, Test
using CUDA
includet("C:\\GitHub\\GitHub\\NuclearMedEval\\test\\includeAllUseFullForTest.jl")
using Main.CUDAGpuUtils ,Main.IterationUtils,Main.ReductionUtils , Main.MemoryUtils,Main.CUDAAtomicUtils
using Main.MetadataAnalyzePass,Main.MetaDataUtils,Main.WorkQueueUtils,Main.ProcessMainDataVerB,Main.HFUtils,Main.ResultListUtils

threads=(32,5);
blocks =1;
mainArrDims= (67,177,90);
dataBdim = (10,10,10)
mainArrCPU= falses(mainArrDims);
refArrCPU = falses(mainArrDims);
##### we will create two planes 20 units apart from each 
mainArrCPU[10:50,10:50,10]= true
refArrCPU[10:50,10:50,30]= true
metaData = MetaDataUtils.allocateMetadata(mainArrDims,dataBdim);
metaDataDims= size(metaData);
loopAXFixed,loopBXfixed,loopAYFixed,loopBYfixed,loopAZFixed,loopBZfixed,loopdataDimMainX,loopdataDimMainY,loopdataDimMainZ,inBlockLoopX,inBlockLoopY,inBlockLoopZ,metaDataLength,loopMeta,loopWarpMeta=calculateLoopsIter(dataBdim,threads[1],threads[2],metaDataDims,blocks)

loopAXFixed,loopBXfixed,loopAYFixed,loopBYfixed,loopAZFixed,loopBZfixed,loopdataDimMainX,loopdataDimMainY,loopdataDimMainZ,inBlockLoopX,inBlockLoopY,inBlockLoopZ,metaDataLength,loopMeta,loopWarpMeta = calculateLoopsIter(dataBdim,threads[1],threads[2],metaDataDims,blocks)
    minxRes,maxxRes,minyRes,maxyRes,minzRes,maxzRes,fn,fp  =getSmallForBoolKernel();
    reducedGoldA,reducedSegmA,reducedGoldB,reducedSegmB=  getLargeForBoolKernel(mainArrDims);


    
mainArrGPU = CuArray(mainArrCPU);
refArrGPU= CuArray(mainArrCPU);
    """
    for invoking getBoolCubeKernel
    """
    function boolKernelLoad(mainArrDims,dataBdim,metaData,metaDataDims,reducedGoldA,reducedSegmA,reducedGoldB,reducedSegmB,minxRes,maxxRes,minyRes,maxyRes,minzRes,maxzRes,fn,fp ,gold3d,segm3d,numberToLooFor,loopAXFixed,loopBXfixed,loopAYFixed,loopBYfixed,loopAZFixed,loopBZfixed,loopdataDimMainX,loopdataDimMainY,loopdataDimMainZ,inBlockLoopX,inBlockLoopY,inBlockLoopZ,metaDataLength,loopMeta,loopWarpMeta)
        @getBoolCubeKernel()
    return
    end
"""
main function responsible for calculations of Housedorff distance
"""
function mainKernelLoad()
    @mainLoopKernel
end
boolKernelArgs = (mainArrDims,dataBdim,metaData,metaDataDims,reducedGoldA,reducedSegmA,reducedGoldB,reducedSegmB,minxRes,maxxRes,minyRes,maxyRes,minzRes,maxzRes,fn,fp ,gold3d,segm3d,numberToLooFor,loopAXFixed,loopBXfixed,loopAYFixed,loopBYfixed,loopAZFixed,loopBZfixed,loopdataDimMainX,loopdataDimMainY,loopdataDimMainZ,inBlockLoopX,inBlockLoopY,inBlockLoopZ,metaDataLength,loopMeta,loopWarpMeta)

totalFp,totalFn = 1,1 #later we will increase it 
resList,resListIndicies= allocateResultLists(totalFp,totalFn)
workQueaue= WorkQueueUtils.allocateWorkQueue(totalFp,totalFn)

workQueaueCounter= CUDA.zeros(UInt32,1)

mainKernelArgs= ()

function get_shmemBoolKernel()
    resShmem = cld((dataBdim[1]+2)*(dataBdim[2]+2)*(dataBdim[2]+2),8) #dividing by 8 as we want bytes
    sourceShmem = cld((dataBdim[1])*(dataBdim[2])*(dataBdim[2]),8) #dividing by 8 as we want bytes
    shmemSum= cld(36*14*32,8)
    areToBeValidated= cld(14,8)
    isAnythingInPadding= cld(6,8)
    alreadyCoveredInQueues= cld(32*14,8)
    someBools = 3
    return resShmem+sourceShmem+shmemSum+areToBeValidated+isAnythingInPadding+alreadyCoveredInQueues+someBools
end

function get_shmemMainKernel()
    shmemSum= cld(32*32*2,8)
    minMaxes = 6
    localQuesValues = cld(32*14,8)
    return shmemSum+minMaxes+localQuesValues
end

## now we need to make use of occupancy API to get optimal number of threads and blocks fo each kernel
threadsBoollKernel,blocksBoollKernel = getThreadsAndBlocksNumbForKernel(get_shmemBoolKernel,kernelFun,args)
threadsMainHKernel,blocksMainHKernel = getThreadsAndBlocksNumbForKernel(get_shmemMainKernel,kernelFun,args)


"""
connecs all functions to complete Housedorff distance kernel Lounch
"""
function fullHouseDorfKernelAct()
    
    @cuda threads=threads blocks=blocks boolKernelLoad(mainArrDims,dataBdim,metaData,metaDataDims,reducedGoldA,reducedSegmA,reducedGoldB,reducedSegmB,minxRes,maxxRes,minyRes,maxyRes,minzRes,maxzRes,fn,fp ,gold3d,segm3d,numberToLooFor,loopAXFixed,loopBXfixed,loopAYFixed,loopBYfixed,loopAZFixed,loopBZfixed,loopdataDimMainX,loopdataDimMainY,loopdataDimMainZ,inBlockLoopX,inBlockLoopY,inBlockLoopZ,metaDataLength,loopMeta,loopWarpMeta)
    #now time to get data structures dependent on bool kernel like for example loading subsections of meta data, creating work queue ...
    
    krowa
    #main calculations
    @cuda threads=threads blocks=blocks  cooperative=true mainKernelLoad()
end    


@cuda threads=threads blocks=blocks executeDataIterWithPaddingKernel(isAnythingInPadding,areToBeValidated,sourceShmem,inBlockLoopX,inBlockLoopY,inBlockLoopZ,resShmem,metaData,resList,resListIndicies,metaDataDims,refArrGPU,mainArrDims,loopAXFixed,loopBXfixed,loopAYFixed,loopBYfixed,loopAZFixed,loopBZfixed,loopdataDimMainX,loopdataDimMainY,loopdataDimMainZ,dataBdim,mainArrGPU,iterNumb,isGold,xMeta,yMeta,zMeta,isToBeValidated)

metaCorrX = 2
metaCorrY = 2
metaCorrZ = 2
@test  metaData[metaCorrX,metaCorrY,metaCorrZ,getFullInSegmNumb()-1]==0
