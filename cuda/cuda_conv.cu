/*
   This file is part of the libds by b. Charlier and J. Glaunes
*/

#include <stdio.h>
#include <assert.h>
#include <cuda.h>
#include "radial_kernels.cx"


#define UseCudaOnDoubles USE_DOUBLE_PRECISION

///////////////////////////////////////
/////////// CUDA KERNEL ///////////////
///////////////////////////////////////
#if !(UseCudaOnDoubles) 
typedef  float(*KernelFun)( float,  float);
#else
typedef double(*KernelFun)(double, double);
#endif

template < typename TYPE, int DIMPOINT, int DIMVECT, KernelFun KernelF >
__global__ void KernelGpuConvOnDevice(TYPE ooSigma2,
                                      TYPE *x, TYPE *y, TYPE *beta, TYPE *gamma,
                                      int nx, int ny) {
    // Thread kernel:
    // Computation of gamma_i = sum_j k(x_i,y_j)*beta_j for index i given by thread id.
    // 
    
    int i = blockIdx.x * blockDim.x + threadIdx.x;

    extern __shared__ TYPE SharedData[];  // shared data will contain x and alpha data for the block
    
    // One thread = One line = One x_i + One gamma_i + a whole bunch of "y_j".
    TYPE xi[DIMPOINT], gammai[DIMVECT];
    if(i<nx){  // we will compute gammai only if i is in the range 
        for(int k=0; k<DIMPOINT; k++)
            xi[k] = x[i*DIMPOINT+k];  // Load xi from device global memory
        for(int k=0; k<DIMVECT; k++)  
            gammai[k] = 0.0f;         // Make sure to put to zero the output array 
    }
    
    // All the "y_j" may not fit in the shared memory, so we cut the arrays "y" and "b"
    // into tiles of size blockDim.x. 
    //
    //   Mathematically speaking, we're doing the "Gamma = K(x,y) @ b" matrix product
    //   block-by-block, with K-tiles of size "blockDim.x * blockDim.x".
    //
    //
    //                     <-- blockDim.x -->                         <-- Use the "j<ny" condition here !
    //   +-----------------+-----------------+-----------------+------+
    //   |                 |                 |                 |      |
    //   |                 |                 |                 |      |
    //   |                 |                 |                 |      |
    // i |                 |    k(x_i,y_j)   |                 |      |
    //   |                 |                 |                 |      |
    //   |                 |                 |                 |      |
    //   |                 |                 |                 |      |
    //   +-----------------+-----------------+-----------------+------+
    //   |                 |                 |                 |      |
    //   |                 |                 |                 |      |
    //   |                 |                 |                 |      |
    //   |                 |                 |                 |      |
    //   |                 |                 |                 |      |
    //   |                 |                 |                 |      |
    //   |                 |                 |                 |      |
    //   +-----------------+-----------------+-----------------+------+
    //   |                 |                 |                 |      |
    //   |                 |                 |                 |      |
    //   |                 |                 |                 |      |
    //   +-----------------+-----------------+-----------------+------+
    //
    //   The whole point of this code, however, is to never store the big matrix,
    //   or even the tiles, in the GPU memory :
    //   We will simply store x_i, + the y_j and b_j and use for loops
    //   in order to fill in the product lines gamma_i 
    //
    // We use all the threads to load the tiles in the memory :
    for(int jstart = 0, tile = 0; jstart < ny; jstart += blockDim.x, tile++) {

        // Load data in Shared memory -----------------------------------------------------------
        int j = tile * blockDim.x + threadIdx.x; // Current column
        // We load yj and betaj from device global memory...
        if(j<ny){ // ...only if j<ny (we may be in the last columns of the last tile...)
            // Pretty uneasy to read : we store yj and betaj interleaved, for better performance
            // SharedData = "[ y0, b0, y1, b1, y2, b2, ... ]"
            int inc = DIMPOINT + DIMVECT; // Size of a  [yj, bj] block
            for(int k=0; k<DIMPOINT; k++)
                SharedData[threadIdx.x*inc+k]          =    y[j*DIMPOINT+k];
            for(int k=0; k<DIMVECT; k++)
                SharedData[threadIdx.x*inc+DIMPOINT+k] = beta[j*DIMVECT +k];
        }
        __syncthreads();
        // At this point :
        // - x_i sits in the thread memory
        // - [y_N, ..., y_{N+blockDim.x}] and [b_N, ..., b_{N+blockDim.x}] sit
        //   in the SharedData, where [N : N+blockDim.x] is the tile span.
        // - the output line gamma_i is in the thread memory, and contains the result
        //   of the summation over the previous tiles.
        
        
        // Map-Reduction loop -------------------------------------------------------------------
        // We can now proceed to the "tiled" matrix product, where one line = one thread.
        if(i<nx){ // we compute gammai only if needed
            TYPE *yj, *betaj;              // As y_j and beta_j are interleaved...
            yj    = SharedData;            // We'll on some cute pointer arithmetics!
            betaj = SharedData + DIMPOINT; 
            int inc = DIMPOINT + DIMVECT;  // The increment, size of a [y_j,b_j] block.
            for(int jrel = 0; jrel < blockDim.x && jrel<ny-jstart; jrel++, yj+=inc, betaj+=inc) {
                TYPE r2   = 0.0f, temp = 0.0f;
                // Compute x_i-y_j and its squared norm:
                for(int k=0; k<DIMPOINT; k++) {
                    temp    =  xi[k]-yj[k];
                    r2     +=   temp*temp;
                }
                // Straighforward inplace reduction loop over j : at last, we're getting to the maths... **********
                TYPE s = KernelF(r2,ooSigma2);  // The kernel function is stored in "radial_kernels.cx"
                for(int k=0; k<DIMVECT; k++)   // Add the vector s*beta_j to gamma_i 
                    gammai[k] += s * betaj[k]; // (no need to be extra-clever here)
                // ************************************************************************************************
            }
        }
        
        // Once the loop is over, the current tiled matrix product has been reduced to gamma_i
        __syncthreads(); // So make sure that no one's left behind...
        // And move on to the next tile.
    }

    // Save the result in global memory.
    if(i<nx)
        for(int k=0; k<DIMVECT; k++)
            gamma[i*DIMVECT+k] = gammai[k];
}



//////////////////////////////////////////////////////
/////////// CPU -> GPU -> CPU routines ///////////////
//////////////////////////////////////////////////////
#if !(UseCudaOnDoubles) 
template < KernelFun KernelF >
int KernelGpuEvalConv(float ooSigma2,
                                   float* x_h, float* y_h, float* beta_h, float* gamma_h,
                                   int dimPoint, int dimVect, int nx, int ny) {

    //printf("%f %f %f", x_h[0] , x_h[1] ,x_h[2]);

    // Data on the device.
    float* x_d;
    float* y_d;
    float* beta_d;
    float* gamma_d;

    // Allocate arrays on device.
    cudaMalloc((void**)&x_d,     sizeof(float)*(nx*dimPoint));
    cudaMalloc((void**)&y_d,     sizeof(float)*(ny*dimPoint));
    cudaMalloc((void**)&beta_d,  sizeof(float)*(ny*dimVect ));
    cudaMalloc((void**)&gamma_d, sizeof(float)*(nx*dimVect ));

    // Set values to zeros
    cudaMemset(x_d,    0, sizeof(float)*(nx*dimPoint));
    cudaMemset(y_d,    0, sizeof(float)*(ny*dimPoint));
    cudaMemset(beta_d, 0, sizeof(float)*(ny*dimVect ));
    cudaMemset(gamma_d,0, sizeof(float)*(nx*dimVect ));

    // Send data from host to device.
    cudaMemcpy(x_d,    x_h,    sizeof(float)*(nx*dimPoint), cudaMemcpyHostToDevice);
    cudaMemcpy(y_d,    y_h,    sizeof(float)*(ny*dimPoint), cudaMemcpyHostToDevice);
    cudaMemcpy(beta_d, beta_h, sizeof(float)*(ny*dimVect ), cudaMemcpyHostToDevice);

    // Compute on device.
    dim3 blockSize;
    blockSize.x = CUDA_BLOCK_SIZE; // number of threads in each block
    dim3 gridSize;
    gridSize.x =  nx / blockSize.x + (nx%blockSize.x==0 ? 0 : 1);

    // Copy-paste templating, allowing us to pass the DIMPOINT and DIMVECT at compilation time :
    if(     dimPoint==1 && dimVect==1)
        KernelGpuConvOnDevice<float,1,1,KernelF><<<gridSize,blockSize,blockSize.x*(dimVect+dimPoint)*sizeof(float)>>>
        (ooSigma2, x_d, y_d, beta_d, gamma_d, nx, ny);
    else if(dimPoint==3 && dimVect==1)
        KernelGpuConvOnDevice<float,3,1,KernelF><<<gridSize,blockSize,blockSize.x*(dimVect+dimPoint)*sizeof(float)>>>
        (ooSigma2, x_d, y_d, beta_d, gamma_d, nx, ny);
    else if(dimPoint==2 && dimVect==1)
        KernelGpuConvOnDevice<float,2,1,KernelF><<<gridSize,blockSize,blockSize.x*(dimVect+dimPoint)*sizeof(float)>>>
        (ooSigma2, x_d, y_d, beta_d, gamma_d, nx, ny);
    else if(dimPoint==2 && dimVect==2)
        KernelGpuConvOnDevice<float,2,2,KernelF><<<gridSize,blockSize,blockSize.x*(dimVect+dimPoint)*sizeof(float)>>>
        (ooSigma2, x_d, y_d, beta_d, gamma_d, nx, ny);
    else if(dimPoint==3 && dimVect==3)
        KernelGpuConvOnDevice<float,3,3,KernelF><<<gridSize,blockSize,blockSize.x*(dimVect+dimPoint)*sizeof(float)>>>
        (ooSigma2, x_d, y_d, beta_d, gamma_d, nx, ny);
    else {
        printf("Error: dimensions of Gauss kernel not implemented in cuda. You probably just need a copy-paste in the conda_conv.cu file !");
		cudaFree(x_d);
		cudaFree(y_d);
		cudaFree(beta_d);
		cudaFree(gamma_d);
        return(-1);
    }

    // block until the device has completed
    cudaThreadSynchronize();

    // Send data from device to host.
    cudaMemcpy(gamma_h, gamma_d, sizeof(float)*(nx*dimVect),cudaMemcpyDeviceToHost);

    // Free memory.
    cudaFree(x_d);
    cudaFree(y_d);
    cudaFree(beta_d);
    cudaFree(gamma_d);

    return 0;
}


// Couldn't find a clean way to give a name to an explicit instantiation :-(
extern "C" int GaussGpuEvalConv(float ooSigma2,
                                   float* x_h, float* y_h, float* beta_h, float* gamma_h,
                                   int dimPoint, int dimVect, int nx, int ny) {
    return KernelGpuEvalConv<GaussF>(ooSigma2, x_h, y_h, beta_h, gamma_h, dimPoint, dimVect, nx, ny);
}
extern "C" int LaplaceGpuEvalConv(float ooSigma2,
                                   float* x_h, float* y_h, float* beta_h, float* gamma_h,
                                   int dimPoint, int dimVect, int nx, int ny) {
    return KernelGpuEvalConv<LaplaceF>(ooSigma2, x_h, y_h, beta_h, gamma_h, dimPoint, dimVect, nx, ny);
}
extern "C" int EnergyGpuEvalConv(float ooSigma2,
                                   float* x_h, float* y_h, float* beta_h, float* gamma_h,
                                   int dimPoint, int dimVect, int nx, int ny) {
    return KernelGpuEvalConv<EnergyF>(ooSigma2, x_h, y_h, beta_h, gamma_h, dimPoint, dimVect, nx, ny);
}

////////////////////////////////////////////////////
// Just the same, but with double instead of float//
////////////////////////////////////////////////////
#else
extern "C" int GaussGpuEvalConv(double ooSigma2,
                                   double* x_h, double* y_h, double* beta_h, double* gamma_h,
                                   int dimPoint, int dimVect, int nx, int ny) {

    // Data on the device.
    double* x_d;
    double* y_d;
    double* beta_d;
    double* gamma_d;

    // Allocate arrays on device.
    cudaMalloc((void**)&x_d, sizeof(double)*(nx*dimPoint));
    cudaMalloc((void**)&y_d, sizeof(double)*(ny*dimPoint));
    cudaMalloc((void**)&beta_d, sizeof(double)*(ny*dimVect));
    cudaMalloc((void**)&gamma_d, sizeof(double)*(nx*dimVect));

    // Send data from host to device.
    cudaMemcpy(x_d, x_h, sizeof(double)*(nx*dimPoint), cudaMemcpyHostToDevice);
    cudaMemcpy(y_d, y_h, sizeof(double)*(ny*dimPoint), cudaMemcpyHostToDevice);
    cudaMemcpy(beta_d, beta_h, sizeof(double)*(ny*dimVect), cudaMemcpyHostToDevice);

    // Compute on device.
    dim3 blockSize;
    blockSize.x = CUDA_BLOCK_SIZE; // number of threads in each block
    dim3 gridSize;
    gridSize.x =  nx / blockSize.x + (nx%blockSize.x==0 ? 0 : 1);
//test if ggridSIze \leq  65535
    if(dimPoint==1 && dimVect==1)
        KernelGpuConvOnDevice<double,1,1><<<gridSize,blockSize,blockSize.x*(dimVect+dimPoint)*sizeof(double)>>>
        (ooSigma2, x_d, y_d, beta_d, gamma_d, nx, ny);
    else if(dimPoint==3 && dimVect==1)
        KernelGpuConvOnDevice<double,3,1><<<gridSize,blockSize,blockSize.x*(dimVect+dimPoint)*sizeof(double)>>>
        (ooSigma2, x_d, y_d, beta_d, gamma_d, nx, ny);
    else if(dimPoint==2 && dimVect==1)
        KernelGpuConvOnDevice<double,2,1><<<gridSize,blockSize,blockSize.x*(dimVect+dimPoint)*sizeof(double)>>>
        (ooSigma2, x_d, y_d, beta_d, gamma_d, nx, ny);
    else if(dimPoint==2 && dimVect==2)
        KernelGpuConvOnDevice<double,2,2><<<gridSize,blockSize,blockSize.x*(dimVect+dimPoint)*sizeof(double)>>>
        (ooSigma2, x_d, y_d, beta_d, gamma_d, nx, ny);
    else if(dimPoint==3 && dimVect==3)
        KernelGpuConvOnDevice<double,3,3><<<gridSize,blockSize,blockSize.x*(dimVect+dimPoint)*sizeof(double)>>>
        (ooSigma2, x_d, y_d, beta_d, gamma_d, nx, ny);
    else {
        printf("error: dimensions of Gauss kernel not implemented in cuda");
		cudaFree(x_d);
		cudaFree(y_d);
		cudaFree(beta_d);
		cudaFree(gamma_d);
        return(-1);
    }

    // block until the device has completed
    cudaThreadSynchronize();

    // Send data from device to host.
    cudaMemcpy(gamma_h, gamma_d, sizeof(double)*(nx*dimVect),cudaMemcpyDeviceToHost);


    // Free memory.
    cudaFree(x_d);
    cudaFree(y_d);
    cudaFree(beta_d);
    cudaFree(gamma_d);

    return 0;
}
#endif

void ExitFcn(void) {
  cudaDeviceReset();
}

