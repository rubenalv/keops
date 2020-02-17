#pragma once

#include <sstream>

#include "core/formulas/maths/Extract.h"
#include "core/reductions/Reduction.h"
#include "core/reductions/Sum_Reduction.h"
#include "core/formulas/maths/Concat.h"
#include "core/formulas/maths/Scal.h"
#include "core/formulas/maths/Subtract.h"
#include "core/formulas/maths/Exp.h"
#include "core/pre_headers.h"
#include "core/utils/Infinity.h"

// Implements the coupled reduction operation m_i=max_j f_ij, s_i=sum_j exp(f_ij-m_i) g_ij
// where f and g are two formulas. f must be scalar-valued.
// This reduciton is the base for numerically stable computation of log-sum-exp and softmax type reductions.

namespace keops {

template < class F, int tagI = 0, class G_=IntConstant< 1 > >
struct Max_SumShiftExp_Reduction : public Reduction< Concat< F, G_ >, tagI > {

  using G = G_;

  using PARENT = Reduction< Concat< F, G_ >, tagI >;

  static const int DIMRED = G::DIM + F::DIM;                // dimension of temporary variable for reduction

  static const int DIM = DIMRED;

  static_assert(F::DIM == 1, "Max_SumShiftExp requires first formula F of dimension 1.");

  static void PrintId(::std::stringstream &str) {
    str << "Max_SumShiftExp_Reduction(F=";            // prints "("
    F::PrintId(str);                // prints the formula F
    str << ",tagI=" << tagI << ",G=";
    G::PrintId(str);
    str << ")";
  }

  template < typename TYPE >
  struct InitializeReduction {
    DEVICE INLINE void operator()(TYPE *acc) {
      // We fill empty cells with the neutral element of the reduction operation,
      //                   (-inf,0) = e^{-inf} * 0 = 0
#if USE_HALF && GPU_ON
      acc[0] = __float2half2_rn(-65504.);
#pragma unroll
      for (int k = 1; k < DIMRED; k++)
        acc[k] = __float2half2_rn(0.0f);
#elif USE_HALF
#else
      acc[0] = NEG_INFINITY< TYPE >::value;
#pragma unroll
      for (int k = 1; k < DIMRED; k++)
        acc[k] = 0.0f;
#endif
    }
  };

  // equivalent of the += operation
  template < typename TYPEACC, typename TYPE >
  struct ReducePairShort {
    DEVICE INLINE void operator()(TYPEACC *acc, TYPE *xi, int j) {
      // (m,s) + (m',s'), i.e. exp(m)*s + exp(m')*s'
      TYPEACC tmpexp;
      if (acc[0] > xi[0]) { // =  exp(m)  * (s + s'*exp(m'-m))   if m > m'
        tmpexp = exp(xi[0] - acc[0]);
#pragma unroll
        for (int k = 1; k < DIMRED; k++)
          acc[k] += xi[k] * tmpexp;
      } else {             // =  exp(m') * (s' + exp(m-m')*s)   if m <= m'
        tmpexp = exp(acc[0] - xi[0]);
#pragma unroll
        for (int k = 1; k < DIMRED; k++)
          acc[k] = xi[k] + tmpexp * acc[k];
        acc[0] = xi[0];
      }
    }
  };

  // equivalent of the += operation
  template < typename TYPEACC, typename TYPE >
  struct ReducePair {
    DEVICE INLINE void operator()(TYPEACC *acc, TYPE *xi) {
      // (m,s) + (m',s'), i.e. exp(m)*s + exp(m')*s'
      TYPEACC tmpexp;
      if (acc[0] > xi[0]) { // =  exp(m)  * (s + s'*exp(m'-m))   if m > m'
        tmpexp = exp(xi[0] - acc[0]);
#pragma unroll
        for (int k = 1; k < DIMRED; k++)
          acc[k] += xi[k] * tmpexp;
      } else {             // =  exp(m') * (s' + exp(m-m')*s)   if m <= m'
        tmpexp = exp(acc[0] - xi[0]);
#pragma unroll
        for (int k = 1; k < DIMRED; k++)
          acc[k] = xi[k] + tmpexp * acc[k];
        acc[0] = xi[0];
      }
    }
  };

  // Kahan scheme
  template < typename TYPEACC, typename TYPE >
  struct KahanScheme {
    static const int DIMACC = DIMRED-1;
    DEVICE INLINE void operator()(TYPEACC *acc, TYPE *xi, TYPE *tmp) {
      // (m,s) + (m',s'), i.e. exp(m)*s + exp(m')*s'
      TYPEACC tmpexp;
      if (acc[0] > xi[0]) { // =  exp(m)  * (s + s'*exp(m'-m))   if m > m'
        tmpexp = exp(xi[0] - acc[0]);
#pragma unroll
	for (int k=1; k<DIMRED; k++)
        {
		TYPEACC a = xi[k] * tmpexp - tmp[k-1];
		TYPEACC b = acc[k] + a;
		tmp[k-1] = (b - acc[k]) - a;
		acc[k] = b;
	}
      } else {             // =  exp(m') * (s' + exp(m-m')*s)   if m <= m'
        tmpexp = exp(acc[0] - xi[0]);
#pragma unroll
        for (int k = 1; k < DIMRED; k++)
        {
		TYPEACC u = tmpexp * acc[k];
		TYPEACC a = xi[k] - tmpexp * tmp[k-1];
		TYPEACC b = u + a;
		tmp[k-1] = (b - u) - a;
		acc[k] = b;
	}
	acc[0] = xi[0];
      }
    }
  };

  template < typename TYPEACC, typename TYPE >
  struct FinalizeOutput {
    DEVICE INLINE void operator()(TYPEACC *acc, TYPE *out, TYPE **px, int i) {
#pragma unroll
      for (int k = 0; k < DIM; k++)
        out[k] = acc[k];
    }
  };

  // Beware: the formula that we use for the gradient is *only* valid
  // if the output [M,S] = Max_SumShiftExp(F,G) has been flattened through a
  // L = M + log(S) (Log-Sum-Exp) or a weighted Soft-Max
  // operation (as done by the Python bindings), and if 
  // GRADIN = [Grad(L), Grad(L)/S ]
  // has been backpropagated from L.

  template < class MS >
  using M = Extract< MS, 0, F::DIM >;

  template < class MS >
  using S = Extract< MS, F::DIM, G::DIM >;

  template < class V, class GRADIN, class MS >
  using DiffT = Grad< Sum_Reduction< Scal< Exp< Subtract< F, M< MS>> >, G >, tagI >, V, S< GRADIN>>;

  // remark : if V::CAT is 2 (parameter), we will get tagI=(V::CAT)%2=0, so we will do reduction wrt j.
  // In this case there is a summation left to be done by the user.

};

#define Max_SumShiftExp_Reduction(F, I) KeopsNS<Max_SumShiftExp_Reduction<decltype(InvKeopsNS(F)),I>>()
#define Max_SumShiftExpWeight_Reduction(F, I, G) KeopsNS<Max_SumShiftExp_Reduction<decltype(InvKeopsNS(F)),I,decltype(InvKeopsNS(G))>>()

}
