# cython external imports
from libc.math cimport log
from libc.stdlib cimport rand, srand, RAND_MAX
from libc.time cimport time
from cpython.array cimport array

# import intra-package cython dependencies
from ..signals.signals cimport cSignalType
from .deterministic cimport cDeterministicSystem

# seed random number generator
srand(time(NULL))


cdef class cStochasticSystem(cDeterministicSystem):

    # attributes
    cdef bint integrate
    cdef bint null_input
    cdef array samples
    cdef unsigned int *rxn_order
    cdef unsigned int *states
    cdef double *inputs
    cdef double *cumulative
    cdef double sampling_interval
    cdef unsigned int sample_index
    cdef double sample_time

    # methods
    cdef void allocate_memory(self)

    cdef void set_states(self, unsigned int[:] x) nogil

    cdef void set_inputs(self, double[:] x) nogil

    cdef void set_cumulative(self, double[:] x) nogil

    cdef void set_rxn_order(self, double *rates)

    cpdef tuple run(self,
        unsigned int[:] ic,
        double[:] integrator_ic,
        cSignalType signal,
        double duration=*,
        double sampling_interval=*,
        int seed=*)

    cdef void ssa(self,
        cSignalType signal,
        double duration,
        double sampling_interval) nogil

    cdef unsigned int choose_rxn(self,
        double random) nogil

    cdef void fire_reaction(self,
        unsigned int rxn,
        unsigned int extent,
        unsigned int *states) nogil

    cdef void update_cumulative(self,
        unsigned int *states,
        double *cumulative,
        double tau) nogil

    cdef void sample(self) nogil

    cdef void record(self,
        double end_time) nogil


# ======================== STANDALONE FUNCTIONS ===============================


cdef inline int rand_open() nogil:
    """ Returns random integer on the open interval (0, RAND_MAX). """
    cdef int random_int = rand()
    if random_int == 0 or random_int == RAND_MAX:
        random_int = rand_open()
    return random_int


cdef inline double sum_double_arr(double* values, unsigned int N) nogil:
    """ Returns the sum of <N> indepndent <values>. """
    cdef unsigned int i
    cdef double total = 0
    for i in xrange(N):
        total += values[i]
    return total


cdef inline double evaluate_timestep(double total_rate, double random) nogil:
    """
    Evaluate and return time until next reaction. Time interval is sampled from an exponential distribution.

    Args:

        total_rate (double) - total reaction rate

        random (double) - random float on [0, 1) interval

    Returns:

        tau (double) - time until next reaction event

    """
    return (1/total_rate) * log(1/random)


cdef inline unsigned int choose_rxn(unsigned int* order,
                                     double* rates,
                                     unsigned int num_rxns,
                                     double total_rate,
                                     double random) nogil:
    """
    Select a reaction from a list, with probabilities proportionally weighted by the rate of each reaction.

    Args:

        order (unsigned int*) - reaction sort order

        rates (double*) - reaction rates

        num_rxns (unsigned int) - number of reactions

        total_rate (double) - total reaction rate

        random (double) - random float on [0, 1) interval

    Returns:

        rxn (unsigned int) - chosen reaction index

    Notes:

        - If the random number is high and the previous reaction puts the rate over the total rate, the r<=0 comparison is never activated and the index isn't incremented by the subsequent loop. The solution implemented here is to correct index following the comparison.

    """
    cdef double rate = 0
    cdef double r
    cdef unsigned int index

    r = total_rate * random
    for index in xrange(num_rxns):
        rate = rates[order[index]]
        r -= rate
        if r <= 0:
            break

    # recurse with a new random float (accounts for roundoff error)
    if r > 0:
        #random = rand()/(RAND_MAX+1.0)
        total_rate = sum_double_arr(rates, num_rxns)
        rxn = choose_rxn(order, rates, num_rxns, total_rate, random)
    else:
        rxn = order[index]

    return rxn
