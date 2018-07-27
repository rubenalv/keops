// test convolution
// compile with
//		nvcc -I.. -DCUDA_BLOCK_SIZE=192 -Wno-deprecated-gpu-targets -D__TYPE__=float -std=c++11 -O2 -o build/test_logsumexp test_logsumexp.cu
// 

#include <stdio.h>
#include <assert.h>
#include <vector>
#include <cuda.h>
#include <ctime>
#include <algorithm>
#include <iostream>

#include "core/formulas/constants.h"
#include "core/formulas/maths.h"
#include "core/formulas/kernels.h"
#include "core/formulas/norms.h"
#include "core/formulas/factorize.h"

#include "core/CpuConv.cpp"
#include "core/GpuConv1D.cu"
#include "core/GpuConv2D.cu"

using namespace keops;

__TYPE__ floatrand() {
    return ((__TYPE__) std::rand())/RAND_MAX-.5;    // random value between -.5 and .5
}

template < class V > void fillrandom(V& v) {
    generate(v.begin(), v.end(), floatrand);    // fills vector with random values
}

#define DIMPOINT 3
#define DIMVECT 1

int main() {

    // symbolic expression of the function : linear combination of 4 gaussians
    using C = _P<0,1>;
    using X = _X<1,DIMPOINT>;
    using Y = _Y<2,DIMPOINT>;
    using B = _Y<3,DIMVECT>;
    
    using F = GaussKernel<C,X,Y,B>;

    std::cout << std::endl << "Function F : " << std::endl;
    std::cout << PrintFormula<F>();
    std::cout << std::endl << std::endl;

    using FUNCONVF = typename LogSumExpReduction<F>::sEval;

    using ExpF = Exp<F>;

    std::cout << std::endl << "Function ExpF : " << std::endl;
    std::cout << PrintFormula<ExpF>();
    std::cout << std::endl << std::endl;

    using FUNCONVEXPF = typename SumReduction<ExpF>::sEval;

    // now we test ------------------------------------------------------------------------------

    std::cout << "Testing LogSumExp reduction" << std::endl;

    int Nx=5000, Ny=2000;
        
    std::vector<__TYPE__> vf(Nx*F::DIM);    fillrandom(vf); __TYPE__ *f = vf.data();
    std::vector<__TYPE__> vx(Nx*DIMPOINT);    fillrandom(vx); __TYPE__ *x = vx.data();
    std::vector<__TYPE__> vy(Ny*DIMPOINT);    fillrandom(vy); __TYPE__ *y = vy.data();
    std::vector<__TYPE__> vb(Ny*DIMVECT); fillrandom(vb); __TYPE__ *b = vb.data();

    std::vector<__TYPE__> rescpu1(Nx*F::DIM);

    __TYPE__ oos2[1] = {.5};

    clock_t begin, end;

    begin = clock();
    CpuConv(FUNCONVF(), Nx, Ny, f, oos2, x, y, b);
    end = clock();
    std::cout << "time for CPU computation : " << double(end - begin) / CLOCKS_PER_SEC << std::endl;

    rescpu1 = vf;


    // display values
    std::cout << "rescpu1 = ";
    for(int i=0; i<5; i++)
        std::cout << rescpu1[i] << " ";
    std::cout << "..." << std::endl << std::endl;
    
    std::cout << "Testing Log of Sum reduction of Exp" << std::endl;

    std::vector<__TYPE__> rescpu2(Nx*F::DIM);

    begin = clock();
    CpuConv(FUNCONVEXPF(), Nx, Ny, f, oos2, x, y, b);
    for(int i=0; i<vf.size(); i++)
    	vf[i] = log(vf[i]);
    end = clock();
    std::cout << "time for CPU computation : " << double(end - begin) / CLOCKS_PER_SEC << std::endl;

    rescpu2 = vf;


    // display values
    std::cout << "rescpu2 = ";
    for(int i=0; i<5; i++)
        std::cout << rescpu2[i] << " ";
    std::cout << "..." << std::endl << std::endl;

    // display mean of errors
    __TYPE__ s = 0;
    for(int i=0; i<Nx*F::DIM; i++)
        s += std::abs(rescpu1[i]-rescpu2[i]);
    std::cout << std::endl << "mean abs error = " << s/Nx << std::endl << std::endl;

    GpuConv1D(FUNCONVF(), Nx, Ny, f, oos2, x, y, b);	// first dummy call to Gpu

    begin = clock();
    GpuConv1D(FUNCONVF(), Nx, Ny, f, oos2, x, y, b);
    end = clock();
    std::cout << "time for GPU computation (1D scheme) : " << double(end - begin) / CLOCKS_PER_SEC << std::endl;

    std::vector<__TYPE__> resgpu1(Nx*F::DIM);
    resgpu1 = vf;

    // display values
    std::cout << "resgpu1 = ";
    for(int i=0; i<5; i++)
        std::cout << resgpu1[i] << " ";
    std::cout << "..." << std::endl << std::endl;
    
    begin = clock();
    GpuConv2D(FUNCONVF(), Nx, Ny, f, oos2, x, y, b);
    end = clock();
    std::cout << "time for GPU computation (2D scheme) : " << double(end - begin) / CLOCKS_PER_SEC << std::endl;

    std::vector<__TYPE__> resgpu2(Nx*F::DIM);
    resgpu2 = vf;

    // display values
    std::cout << "resgpu2 = ";
    for(int i=0; i<5; i++)
        std::cout << resgpu2[i] << " ";
    std::cout << "..." << std::endl << std::endl;
    

    std::cout << "Testing Gradient of LogSumExp reduction" << std::endl;

    using E = _X<5,DIMVECT>;
    using G = Grad<F,X,E>;

}



