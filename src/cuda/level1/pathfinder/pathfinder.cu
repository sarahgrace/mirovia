#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <fstream>

#include "OptionParser.h"
#include "ResultDatabase.h"
#include "Utility.h"
#include "cudacommon.h"

#define BLOCK_SIZE 256
#define STR_SIZE 256
#define HALO 1  // halo width along one direction when advancing to the next iteration
#define SEED 7

void run(long long borderCols, long long smallBlockCol, long long blockCols, ResultDatabase &resultDB, OptionParser &op);

long long rows, cols;
long long *data;
long long **wall;
long long *result;
long long pyramid_height;

// ****************************************************************************
// Function: addBenchmarkSpecOptions
//
// Purpose:
//   Add benchmark specific options parsing.  The user is allowed to specify
//   the size of the input data in kiB.
//
// Arguments:
//   op: the options parser / parameter database
//
// Programmer: Anthony Danalis
// Creation: September 08, 2009
// Returns:  nothing
//
// ****************************************************************************
void addBenchmarkSpecOptions(OptionParser &op) {
  op.addOption("rows", OPT_INT, "0", "number of rows");
  op.addOption("cols", OPT_INT, "0", "number of cols");
  op.addOption("pyramidHeight", OPT_INT, "0", "pyramid height");
  op.addOption("resultsfile", OPT_STRING, "", "file to write results to");
}

// ****************************************************************************
// Function: RunBenchmark
//
// Purpose:
//   Executes the pathfinder benchmark
//
// Arguments:
//   resultDB: results from the benchmark are stored in this db
//   op: the options parser / parameter database
//
// Returns:  nothing, results are stored in resultDB
//
// Programmer: Kyle Spafford
// Creation: August 13, 2009
//
// Modifications:
//
// ****************************************************************************
void RunBenchmark(ResultDatabase &resultDB, OptionParser &op) {
  int device;
  cudaGetDevice(&device);
  cudaDeviceProp deviceProp;
  cudaGetDeviceProperties(&deviceProp, device);

  long long rowLen = op.getOptionInt("rows");
  long long colLen = op.getOptionInt("cols");
  long long pyramidHeight = op.getOptionInt("pyramidHeight");
  
  if(rowLen == 0 || colLen == 0 || pyramidHeight == 0) {
      printf("Parameters not fully specified, using preset problem size\n");
      long long rowSizes[4] = {8, 16, 32, 64};
      long long colSizes[4] = {1, 8, 16, 32};
      long long pyramidSizes[4] = {4, 8, 16, 32};
      rows = rowSizes[op.getOptionInt("size") - 1];
      cols = colSizes[op.getOptionInt("size") - 1] * 1024 * 1024;
      pyramid_height = pyramidSizes[op.getOptionInt("size") - 1];
  } else {
      rows = rowLen;
      cols = colLen;
      pyramid_height = pyramidHeight;
  }

  printf("Row length: %lld\n", rows);
  printf("Column length: %lld\n", cols);
  printf("Pyramid height: %lld\n", pyramid_height);

  /* --------------- pyramid parameters --------------- */
  long long borderCols = (pyramid_height)*HALO;
  long long smallBlockCol = BLOCK_SIZE - (pyramid_height)*HALO * 2;
  long long blockCols = cols / smallBlockCol + ((cols % smallBlockCol == 0) ? 0 : 1);

  printf(
          "gridSize: [%lld],border:[%lld],blockSize: "
          "[%d],blockGrid:[%lld],targetBlock:[%lld]\n",
          cols, borderCols, BLOCK_SIZE, blockCols, smallBlockCol);

  long long passes = op.getOptionInt("passes");
  for(long long i = 0; i < passes; i++) {
    printf("Pass %lld: ", i);
    run(borderCols, smallBlockCol, blockCols, resultDB, op);
    printf("Done.\n");
  }
}

void init(OptionParser &op) {
  data = new long long[rows * cols];
  wall = new long long *[rows];
  for (long long n = 0; n < rows; n++) wall[n] = data + (long long)cols * n;
  result = new long long[cols];

  srand(SEED);

  for (long long i = 0; i < rows; i++) {
    for (long long j = 0; j < cols; j++) {
      wall[i][j] = rand() % 10;
    }
  }
  string resultsfile = op.getOptionString("resultsfile");
  if(resultsfile != "") {
    std::fstream fs;
    fs.open(resultsfile.c_str(), std::fstream::in);
    fs.close();
  }
}

void fatal(char *s) { fprintf(stderr, "error: %s\n", s); }

#define IN_RANGE(x, min, max) ((x) >= (min) && (x) <= (max))
#define CLAMP_RANGE(x, min, max) x = (x < (min)) ? min : ((x > (max)) ? max : x)
#define MIN(a, b) ((a) <= (b) ? (a) : (b))

__global__ void dynproc_kernel(long long iteration, long long *gpuWall, long long *gpuSrc,
                               long long *gpuResults, long long cols, long long rows,
                               long long startStep, long long border) {
  __shared__ long long prev[BLOCK_SIZE];
  __shared__ long long result[BLOCK_SIZE];

  long long bx = blockIdx.x;
  long long tx = threadIdx.x;

  // each block finally computes result for a small block
  // after N iterations.
  // it is the non-overlapping small blocks that cover
  // all the input data

  // calculate the small block size
  long long small_block_cols = BLOCK_SIZE - iteration * HALO * 2;

  // calculate the boundary for the block according to
  // the boundary of its small block
  long long blkX = (long long)small_block_cols * (long long)bx - (long long)border;
  long long blkXmax = blkX + (long long)BLOCK_SIZE - 1;

  // calculate the global thread coordination
  long long xidx = blkX + (long long)tx;

  // effective range within this block that falls within
  // the valid range of the input data
  // used to rule out computation outside the boundary.
  long long validXmin = (blkX < 0) ? -blkX : 0;
  long long validXmax = (blkXmax > (long long)cols - 1) ? (long long)BLOCK_SIZE - 1 - (blkXmax - (long long)cols + 1)
                                       : (long long)BLOCK_SIZE - 1;

  long long W = tx - 1;
  long long E = tx + 1;

  W = (W < validXmin) ? validXmin : W;
  E = (E > validXmax) ? validXmax : E;

  bool isValid = IN_RANGE(tx, validXmin, validXmax);

  if (IN_RANGE(xidx, 0, (long long)cols - 1)) {
    prev[tx] = gpuSrc[xidx];
  }
  __syncthreads();  // [Ronny] Added sync to avoid race on prev Aug. 14 2012
  bool computed;
  for (long long i = 0; i < iteration; i++) {
    computed = false;
    if (IN_RANGE(tx, i + 1, BLOCK_SIZE - i - 2) && isValid) {
      computed = true;
      long long left = prev[W];
      long long up = prev[tx];
      long long right = prev[E];
      long long shortest = MIN(left, up);
      shortest = MIN(shortest, right);
      long long index = cols * (startStep + i) + xidx;
      result[tx] = shortest + gpuWall[index];
    }
    __syncthreads();
    if (i == iteration - 1) break;
    if (computed)  // Assign the computation range
      prev[tx] = result[tx];
    __syncthreads();  // [Ronny] Added sync to avoid race on prev Aug. 14 2012
  }

  // update the global memory
  // after the last iteration, only threads coordinated within the
  // small block perform the calculation and switch on ``computed''
  if (computed) {
    gpuResults[xidx] = result[tx];
  }
}

/*
   compute N time steps
*/
long long calc_path(long long *gpuWall, long long *gpuResult[2], long long rows, long long cols,
              long long pyramid_height, long long blockCols, long long borderCols, double& kernelTime) {
  dim3 dimBlock(BLOCK_SIZE);
  dim3 dimGrid(blockCols);

  cudaEvent_t start, stop;
  cudaEventCreate(&start);
  cudaEventCreate(&stop);
  float elapsedTime;

  long long numStreams = 1;
  cudaStream_t streams[numStreams];
  for(long long s = 0; s < numStreams; s++) {
      cudaStreamCreate(&streams[s]);
  }
  long long src = 1, dst = 0;
  for (long long t = 0; t < rows - 1; t += pyramid_height) {
    for(long long s = 0; s < numStreams; s++) {
    long long temp = src;
    src = dst;
    dst = temp;

#ifdef HYPERQ
    if(t == 0 && s == 0) {
        cudaEventRecord(start, streams[s]);
    }
    dynproc_kernel<<<dimGrid, dimBlock, 0, streams[s]>>>(
        MIN(pyramid_height, rows - t - 1), gpuWall, gpuResult[src],
        gpuResult[dst], cols, rows, t, borderCols);
    if(t + pyramid_height >= rows - 1 && s == numStreams - 1) {
        cudaDeviceSynchronize();
        cudaEventRecord(stop, streams[s]);
        cudaEventSynchronize(stop);
        CHECK_CUDA_ERROR();
        cudaEventElapsedTime(&elapsedTime, start, stop);
        kernelTime += elapsedTime * 1.e-3;
    }
#else
    cudaEventRecord(start, 0);
    dynproc_kernel<<<dimGrid, dimBlock>>>(
        MIN(pyramid_height, rows - t - 1), gpuWall, gpuResult[src],
        gpuResult[dst], cols, rows, t, borderCols);
    cudaDeviceSynchronize();
    cudaEventRecord(stop, 0);
    cudaEventSynchronize(stop);
    CHECK_CUDA_ERROR();
    cudaEventElapsedTime(&elapsedTime, start, stop);
    kernelTime += elapsedTime * 1.e-3;
#endif
      }
    }
  return dst;
}

void run(long long borderCols, long long smallBlockCol, long long blockCols, ResultDatabase &resultDB, OptionParser &op) {
  // initialize data
  init(op);

  long long *gpuWall, *gpuResult[2];
  long long size = rows * cols;

  CUDA_SAFE_CALL(cudaMalloc((void **)&gpuResult[0], sizeof(long long) * cols));
  CUDA_SAFE_CALL(cudaMalloc((void **)&gpuResult[1], sizeof(long long) * cols));
  CUDA_SAFE_CALL(cudaMalloc((void **)&gpuWall, sizeof(long long) * (size - cols)));

  // Cuda events and times
  cudaEvent_t start, stop;
  cudaEventCreate(&start);
  cudaEventCreate(&stop);
  float elapsedTime;
  double transferTime = 0.;
  double kernelTime = 0;

  cudaEventRecord(start, 0);
  CUDA_SAFE_CALL(cudaMemcpy(gpuResult[0], data, sizeof(long long) * cols, cudaMemcpyHostToDevice));
  CUDA_SAFE_CALL(cudaMemcpy(gpuWall, data+cols, sizeof(long long) * (size-cols),
             cudaMemcpyHostToDevice));
  cudaEventRecord(stop, 0);
  cudaEventSynchronize(stop);
  cudaEventElapsedTime(&elapsedTime, start, stop);
  transferTime += elapsedTime * 1.e-3; // convert to seconds

  long long final_ret = calc_path(gpuWall, gpuResult, rows, cols, pyramid_height,
                            blockCols, borderCols, kernelTime);

  cudaEventRecord(start, 0);
  CUDA_SAFE_CALL(cudaMemcpy(result, gpuResult[final_ret], sizeof(long long) * cols,
             cudaMemcpyDeviceToHost));
  cudaEventRecord(stop, 0);
  cudaEventSynchronize(stop);
  cudaEventElapsedTime(&elapsedTime, start, stop);
  transferTime += elapsedTime * 1.e-3; // convert to seconds


  string resultsfile = op.getOptionString("resultsfile");
  if(!resultsfile.empty()) {
    std::fstream fs;
    fs.open(resultsfile.c_str(), std::fstream::app);
    fs << "***DATA***" << std::endl;
    for (long long i = 0; i < cols; i++) {
      fs << data[i] << " ";
    }
    fs << std::endl;
    fs << "***RESULT***" << std::endl;
    for (long long i = 0; i < cols; i++) {
      fs << result[i] << " ";
    }
    fs << std::endl;
  }

  cudaFree(gpuWall);
  cudaFree(gpuResult[0]);
  cudaFree(gpuResult[1]);

  delete[] data;
  delete[] wall;
  delete[] result;

  string atts = toString(rows) + "x" + toString(cols);
  resultDB.AddResult("Pathfinder-TransferTime", atts, "sec", transferTime);
  resultDB.AddResult("Pathfinder-KernelTime", atts, "sec", kernelTime);
  resultDB.AddResult("Pathfinder-TotalTime", atts, "sec", transferTime + kernelTime);
  resultDB.AddResult("Pathfinder-Rate_Parity", atts, "N", transferTime/kernelTime);
}
