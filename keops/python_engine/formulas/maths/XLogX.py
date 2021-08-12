from keops.python_engine.formulas.VectorizedScalarOp import VectorizedScalarOp
from keops.python_engine.formulas.maths.Log import Log
from keops.python_engine.utils.math_functions import keops_xlogx


class XLogX(VectorizedScalarOp):
    """the x*log(x) vectorized operation"""

    string_id = "XLogX"

    ScalarOpFun = keops_xlogx

    @staticmethod
    def Derivative(f):
        return Log(f) + 1


    
    # parameters for testing the operation (optional)
    test_ranges = [(0,2)]           # range of argument
    torch_op = "lambda x:x*torch.log(x)"