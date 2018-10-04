# cython: profile=False

# cython intra-package imports
from ..signals.signals cimport cSignalType, cSignal
from .deterministic cimport cDeterministicSystem

# python intra-package imports
from .deterministic import DeterministicSimulation
from .timeseries import TimeSeries

# cython external imports
from libc.stdlib cimport rand, RAND_MAX
from libc.math cimport log, ceil
from cpython.mem cimport PyMem_Malloc, PyMem_Free
cimport numpy as np
from cpython.array cimport array

# python external imports
import numpy as np
from array import array
from types import FunctionType


# ============================= CYTHON CODE ===================================


cdef double get_timestep(double total_rate,
                         double random) nogil:
    """
    Sample time until next reaction from an exponential distribution.

    Args:

        total_rate (double) - total reaction rate

        random (double) - random float on [0, 1) interval

    Returns:

        tau (double) - time until next reaction event

    """
    return (1/total_rate) * log(1/random)


cdef unsigned int choose_rxn(unsigned int* order,
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
        if r <= 0:
            index -= 1
            break
        r -= rate
    return order[index]



cdef class cStochasticSystem(cDeterministicSystem):
    """
    Class defines a network of nodes that interact via stochastic reactions.

    Attributes:

        states (unsigned int*) - current state values for each node

        inputs (double*) - current input values for each input channel

        cumulative (double*) - current integrator values for each node

        integrate (boolean int) - boolean flag for updating integrator

        rxn_order (unsigned int*) - reaction sort indices

        rstates (array[unsigned int]) - recorded state values for each node

    Inherited Attributes:

        N (unsigned int) - number of nodes

        M (unsigned int) - number of reactions

        I (unsigned int) - number of external inputs

        S (cStoichiometry) - stoichiometry for all reactions

        R (cRates) - rate function for all reactions

    """

    # attributes
    cdef bint integrate
    cdef bint null_input
    cdef array rstates
    cdef unsigned int* rxn_order
    cdef unsigned int* states
    cdef double* inputs
    cdef double* cumulative

    def __init__(self, network):
        """
        Instantiate stochastic simulation.

        Args:

            network (Network) - python network instance

        """

        cdef unsigned int i

        # initialize array for regular states
        self.rstates = array('I', np.zeros(self.N, dtype=np.uint32))

        # set flag for integrator
        if self.R.icontrol.M == 0:
            self.integrate = 0
        else:
            self.integrate = 1

        # initialize simulation variables
        for i in xrange(self.N):
            self.states[i] = 0
            self.cumulative[i] = 0.
        for i in xrange(self.I):
            self.inputs[i] = 0.
        for i in xrange(self.M):
            self.rxn_order[i] = i

    def __cinit__(self, network):
        """ Allocate memory for simulation variables. """
        self.allocate_memory()

    def __dealloc__(self):
        """ Deallocate memory from all array attributes. """
        PyMem_Free(self.rxn_order)
        PyMem_Free(self.states)
        PyMem_Free(self.inputs)
        PyMem_Free(self.cumulative)

    cdef void allocate_memory(self):
        """ Allocate memory for all array attributes. """

        cdef unsigned int size

        # allocate memory for reaction sort indices
        size = self.M * sizeof(unsigned int)
        self.rxn_order = <unsigned int*> PyMem_Malloc(size)
        if not self.rxn_order:
            raise MemoryError('Reaction order memory block not allocated.')

        # allocate memory for states vector
        size = self.N * sizeof(unsigned int)
        self.states = <unsigned int*> PyMem_Malloc(size)
        if not self.states:
            raise MemoryError('States memory block not allocated.')

        # allocate memory for input values vector
        size = self.I * sizeof(double)
        self.inputs = <double*> PyMem_Malloc(size)
        if not self.inputs:
            raise MemoryError('Inputs memory block not allocated.')

        # allocate memory for integrator values vector
        size = self.N * sizeof(double)
        self.cumulative = <double*> PyMem_Malloc(size)
        if not self.cumulative:
            raise MemoryError('Integrator memory block not allocated.')

    cdef void set_states(self, array x) nogil:
        """ Set state values. """
        cdef unsigned int index
        for index in xrange(self.N):
            self.states[index] = x.data.as_uints[index]

    cdef void set_inputs(self, array x) nogil:
        """ Set input values. """
        cdef unsigned int index
        for index in xrange(self.I):
            self.inputs[index] = x.data.as_doubles[index]

    cdef void set_cumulative(self, array x) nogil:
        """ Set integrator values. """
        cdef unsigned int index
        for index in xrange(self.N):
            self.cumulative[index] = x.data.as_doubles[index]

    cdef void set_rxn_order(self, double* rates):
        """
        Order reactions by reaction rate.

        Args:

            rates (double*) - reaction rates

        """
        cdef unsigned int index = 0
        cdef unsigned int rxn
        cdef np.ndarray[double, ndim=1] rates_array
        cdef np.ndarray[unsigned int, ndim=1] order

        # store rates as numpy array and get sorting index
        rates_array = np.asarray(<double[:self.M]> rates)
        order = np.argsort(rates_array).astype(np.uint32)[::-1]

        # copy to reaction order
        for index in xrange(self.M):
            self.rxn_order[index] = order[index]

    cpdef tuple run(self,
                    unsigned int[::1] ic,
                    double[::1] integrator_ic,
                    cSignalType signal,
                    double duration=100,
                    double dt=1.):
        """
        Python interface for stochastic simulation.

        Args:

            ic (int[:]) - initial state values

            integrator_ic (int[:]) - initial integrator values

            signal (cSignalType) - function returning signal values

            duration (double) - simulation length


            dt (double) - sampling interval


        Returns:

            times (np.ndarray[double]) - timepoints, length T

            states (np.ndarray[long]) - interpolated state values, shaped (N,T)

        """

        # initialize times and state lists, simulation counters
        self.set_states(array('I', ic))
        self.set_cumulative(array('d', integrator_ic))

        # initialize signal
        self.null_input = 0
        if signal is None:
            self.null_input = 1
            signal = cSignal([0. for _ in range(self.I)] )
        signal.reset()
        self.set_inputs(signal.get_signal(0))

        # initialize all rates and sort order
        self.R.update_all(self.states, self.inputs, self.cumulative)
        self.set_rxn_order(self.get_rxn_rates())

        # preallocate regular states array to record simulation history
        cdef unsigned int num_timepoints = <unsigned int>ceil(duration/dt)
        rstates = np.empty((self.N, num_timepoints), dtype=np.uint32)
        self.rstates = array('I', rstates.flatten())

        # run stochastic simulation algorithm
        self.ssa(signal=signal, duration=duration, dt=dt)

        #return numpy arrays
        cdef np.ndarray times = np.arange(0, duration, dt)
        cdef np.ndarray states = np.frombuffer(self.rstates, dtype=np.uint32).reshape(self.N, num_timepoints)

        return times, states

    cdef void ssa(self,
                    cSignalType signal,
                    double duration=100,
                    double dt=1.) nogil:
        """
        Run Gillespie SSA.

        Args:

            signal (cSignalType) - function returning signal values

            duration (double) - simulation length

            dt (double) - sampling interval

        """

        # declare variables for time management
        cdef unsigned int index
        cdef unsigned int t_index = 0
        cdef unsigned int s_index
        cdef double t = 0.
        cdef double threshold = 0.
        cdef unsigned int num_timepoints = <unsigned int>ceil(duration/dt)

        # declare items used throughout simulation
        cdef unsigned int rxn = 0
        cdef double tau

        # declare random number
        cdef double rfloat

        # initialize input
        cdef bint changed
        if self.null_input == 0:
            signal.reset()

        # ================================================================
        # BEGIN SIMULATION
        # ================================================================
        while t < duration:

            # update stored state values
            while t >= threshold:
                for s_index in xrange(self.N):
                    self.rstates.data.as_uints[s_index*num_timepoints+t_index] = self.states[s_index]
                threshold += dt
                t_index += 1
                #self.set_rxn_order(self.R.rates)

            # update input value
            if self.null_input == 0:

                # update input value
                signal.update(t)

                # check if input changed and input rates accordingly
                for index in xrange(self.I):
                    changed = signal.compare_value(self.inputs, index)
                    if changed == 1:
                        self.inputs[index] = signal.value.data.as_doubles[index]
                        self.R.update_after_input_change(self.states,
                                                               self.inputs,
                                                               self.cumulative,
                                                               index)

            # update reaction rates
            self.R.update_after_rxn_fired(self.states,
                                                self.inputs,
                                                self.cumulative,
                                                rxn)

            # if total rate is zero, keep stepping until input changes
            if self.R.total_rate == 0:

                # if there is no input, jump to end
                if self.null_input == 1:
                    break
                else:
                    # skip to next change in input
                    changed = 0
                    while t <= duration:
                        signal.update(t)
                        changed = signal.compare_all(self.inputs)
                        if changed == 1:
                            break
                        else:
                            t += dt
                    continue

            # choose a reaction
            rfloat = rand()/(RAND_MAX*1.0)
            tau = get_timestep(self.R.total_rate,
                               rfloat)
            rxn = choose_rxn(self.rxn_order,
                             self.R.rates,
                             self.M,
                             self.R.total_rate,
                             rfloat)

            # fire reaction
            self.fire_reaction(rxn, 1, self.states)

            # increment time and update cumulative state values
            t += tau
            if self.integrate == 1:
                self.update_cumulative(self.states, self.cumulative, tau)

        # ================================================================
        # END SIMULATION
        # ================================================================

        # interpolate any later values
        while threshold < duration:
            for s_index in xrange(self.N):
                self.rstates.data.as_uints[s_index*num_timepoints+t_index] = self.states[s_index]
            threshold += dt
            t_index += 1

    cdef unsigned int choose_rxn(self,
                                 unsigned int *order,
                                 double *rxn_rates,
                                 double total_rate,
                                 double rfloat) nogil:
        """
        Select reaction from given pre-sorted rates (faster).

        Args:

            order (unsigned int*) - reaction sort indices

            rxn_rates (double*) - reaction rates

            total_rate (double) - total reaction rate

            rfloat (double) - random float on [0, 1) interval

        Returns:

            rxn (unsigned int) - reaction index


        """
        return choose_rxn(order, rxn_rates, self.M, total_rate, rfloat)

    cdef array get_input_value(self,
                               cSignalType input_function,
                               double t):
        """
        Returns input values for a specified time.

        Args:

            input_function (cSignalType) - signal generating function

            t (double) - time

        Returns:

            inputs (array[double]) - signal values

        """
        return input_function.get_signal(t)

    cdef void fire_reaction(self,
                            unsigned int rxn,
                            unsigned int extent,
                            unsigned int* states) nogil:
        """
        Fire a specified reaction by updating state values.

        Args:

            rxn (unsigned int) - reaction index

            extent (unsigned int) - reaction extent

            states (unsigned int*) - current state values

        """
        cdef unsigned int N = self.S.lengths[rxn]
        cdef unsigned int index = self.S.index[rxn]
        cdef unsigned int count, species
        cdef int coefficient

        # update each state
        for count in xrange(N):
            species = self.S.species[index]
            coefficient = self.S.coefficients[index]
            states[species] += (coefficient * extent)
            index += 1

    cdef void update_cumulative(self,
                                unsigned int* states,
                                double* cumulative,
                                double tau) nogil:
        """

        Update state integrator values.

        Args:

            states (unsigned int*) - state values

            cumulative (double*) - integrator values

            tau (double) - time step

        """
        cdef unsigned int i
        for i in xrange(self.N):
            cumulative[i] += (tau * states[i])


# ============================= PYTHON CODE ===================================


class StochasticSimulation(DeterministicSimulation):
    """
    Python class for simulating gene regulatory network dynamics using the Gillespie stochastic simulation algorithm.

    Attributes:

        solver (cStochasticSystem) - cython-based stochastic system

    Inherited Attributes:

        N (unsigned int) - number of nodes

        M (unsigned int) - number of reactions

        I (unsigned int) - number of external inputs

    """

    def set_solver(self, network):
        """
        Set stochastic cython-based solver.

        Args:

            network (Network) - python Network instance

        """
        self.solver = cStochasticSystem(network)

    def simulate(self,
            ic=None,
            integrator_ic=None,
            signal=None,
            duration=100.,
            dt=1.):
        """
        Run stochastic simulation.

        Args:

            ic (np.ndarray[np.uint32]) - initial conditions

            integrator_ic (np.ndarray[np.float64]) - integrator initialization

            signal (cSignalType) - returns signal value(s) for a given time

            duration (float) - simulation duration

            dt (float) - sampling interval

        Returns:

            times (np.ndarray[np.float64]) - timepoints, shape (1,t)

            states (np.ndarray[np.uint32]) - state values, shape (N,t)

        """

        # cast initial condition to unsigned 32-bit integer
        if ic is None:
            ic = np.zeros(self.N, dtype=np.uint32)
        else:
            ic = ic.astype(np.uint32)

        # cast integrator initial condition to 64-bit float
        if integrator_ic is None:
            integrator_ic = np.zeros(self.N, dtype=np.float64)
        else:
            integrator_ic = integrator_ic.astype(np.float64)

        # check that initial conditions have the correct dimensions
        assert (ic.size==self.N), 'Wrong IC dimensions.'
        assert (integrator_ic.size==self.N), 'Wrong Integrator IC dimensions.'

        # run stochastic simulation
        dynamics = self.solver.run(ic, integrator_ic, signal, duration, dt)

        return dynamics


class MonteCarloSimulation(StochasticSimulation):
    """
    Python class for simulating multiple gene regulatory network dynamic trajectories using the Gillespie stochastic simulation algorithm.

    Attributes:

        ic (function) - returns initial value vector

        integrator_ic (function) - returns initial integrator value vectors

    Inherited Attributes:

        N (unsigned int) - number of nodes

        M (unsigned int) - number of reactions

        I (unsigned int) - number of external inputs

        solver (cStochasticSystem) - cython-based stochastic system

    """

    def __init__(self,
                 network,
                 condition=None,
                 ic=None,
                 integrator_ic=None):
        """
        Each instance has a fixed set of simulation parameters for which samples are generated.

        Args:

            network (Network) - python Network instance

            condition (str) - environmental condition affecting rates

            ic (array like, tuple, or func) - initial conditions

            integrator_ic (array like, tuple, or func) - integrator initial conditions

        """

        # instantiate simulation
        super().__init__(network, condition)

        # set initial condition generating functions
        self.ic = self.build_ic_generator(ic)
        self.integrator_ic = self.build_ic_generator(integrator_ic)

    # @staticmethod
    # def build_ic_generator(ic, N):
    #     """
    #     Build initial condition generating function. If initial condition values are tuples, treat them as (mean, variance) pairs used to define a normal distribution from which initial conditions are randomly sampled for each trial.

    #     Args:

    #         ic (array like or tuple) - initial condition

    #         N (int) - number of states

    #     Returns:

    #         f (func) - function that returns list of <n> initial value vectors

    #     """

    #     # if ic is a (mean, var) tuple, sample initial conditions from gaussian
    #     if type(ic) == tuple:
    #         m, v = ic
    #         f = lambda n:np.random.normal(m,np.sqrt(v),size=(n, N)).astype(int)

    #     # otherwise if ic is a function, call it for each initial condition
    #     elif type(ic) == types.FunctionType:
    #         f = lambda n: [ic() for _ in range(n)]

    #     # otherwise repeat the same initial condition
    #     else:
    #         f = lambda n: [ic for _ in range(n)]

    #     return f

    @staticmethod
    def build_ic_generator(ic):
        """
        Build initial condition generating function. Behavior is determined by the initial condition data type provided:

        If initial condition is a tuple, treat it as a (mean, variance) pair that defines a normal distribution. Initial conditions are randomly sampled from the distribution for each trial.

        If initial condition is a function, the function output becomes the initial condition for each simulation.

        If initial condition is array like, the same values serve as the initial condition for each simulation.

        Args:

            ic (tuple, function, or array like) - initial condition

        Returns:

            f (func) - function that returns an initial value vector

        """

        # if ic is a (mean, var) tuple, sample initial conditions from gaussian
        if type(ic) == tuple:
            m, v = ic
            f = lambda: np.random.normal(loc=m, scale=np.sqrt(v)).astype(int)

        # otherwise if ic is a function, call it for each initial condition
        elif type(ic) == FunctionType:
            f = lambda: ic()

        # otherwise repeat the same initial condition
        else:
            f = lambda: ic

        return f

    def run(self,
            N=100,
            signal=None,
            duration=100,
            dt=1):
        """
        Run multiple stochastic simulations.

        Args:

            N (int) - number of independent simulation trajectories

            signal (cSignalType) - returns signal value(s) for each time

            duration (float) - simulation duration

            dt (float) - sampling interval

        Returns:

            timeseries (TimeSeries) - system dynamics

        """

        # run each trial, appending sample to a list of all samples
        samples = []
        for i in range(N):

            # generate initial conditions
            ic = self.ic()
            integrator_ic = self.integrator_ic()

            # check that initial condition is positive
            assert (ic<0).sum() == 0, 'Negative IC on trial {:d}'.format(i)

            # run simulation
            times, states = self.simulate(
                ic=ic,
                integrator_ic=integrator_ic,
                signal=signal,
                duration=duration,
                dt=dt)

            # append states vector
            samples.append(states)

        # instantiate time series object
        timeseries = TimeSeries(times, np.array(samples))

        return timeseries



# cdef class cSSA:
#     """
#     Cython class for running a stochastic simulation.

#     Attributes:

#         system (cSystem) - system of nodes and reactions

#         states (unsigned int*) - state values for each node

#         inputs (double*) - input values for each input channel

#         cumulative (double*) - integrated values for each node

#         integrate (boolean int) - boolean flag for running integrator

#         rxn_order (unsigned int*) - order of reaction list

#         rstates (array[unsigned int]) - recorded state values for each node

#     """

#     cdef cSystem system
#     cdef bint integrate
#     cdef bint null_input
#     cdef array rstates
#     cdef unsigned int* rxn_order
#     cdef unsigned int* states
#     cdef double* inputs
#     cdef double* cumulative

#     def __cinit__(self, cSystem system):
#         """
#         Instantiate stochastic simulation.

#         Args:

#             system (cSystem) - system of nodes and reactions

#         """

#         cdef unsigned int i

#         # add network
#         self.system = system

#         # set flags
#         if system.R.icontrol.M == 0:
#             self.integrate = 0
#         else:
#             self.integrate = 1

#         # initialize array for regular states
#         self.rstates = array('I', np.zeros(system.N, dtype=np.uint32))

#         # allocate and populate memory for simulation variables
#         self.allocate_memory()
#         for i in xrange(system.N):
#             self.states[i] = 0
#             self.cumulative[i] = 0.
#         for i in xrange(system.I):
#             self.inputs[i] = 0.
#         for i in xrange(system.M):
#             self.rxn_order[i] = i

#     def __dealloc__(self):
#         """ Deallocate memory from all array attributes. """
#         PyMem_Free(self.rxn_order)
#         PyMem_Free(self.states)
#         PyMem_Free(self.inputs)
#         PyMem_Free(self.cumulative)

#     cdef void allocate_memory(self):
#         """
#         Allocate memory for all array attributes.

#         Note:

#             - memory allocation requires GIL

#         """

#         cdef unsigned int size

#         # allocate memory for reaction sort indices
#         size = self.system.M * sizeof(unsigned int)
#         self.rxn_order = <unsigned int*> PyMem_Malloc(size)
#         if not self.rxn_order:
#             raise MemoryError('Reaction order memory block not allocated.')

#         # allocate memory for states vector
#         size = self.system.N * sizeof(unsigned int)
#         self.states = <unsigned int*> PyMem_Malloc(size)
#         if not self.states:
#             raise MemoryError('States memory block not allocated.')

#         # allocate memory for input values vector
#         size = self.system.I * sizeof(double)
#         self.inputs = <double*> PyMem_Malloc(size)
#         if not self.inputs:
#             raise MemoryError('Inputs memory block not allocated.')

#         # allocate memory for integrator values vector
#         size = self.system.N * sizeof(double)
#         self.cumulative = <double*> PyMem_Malloc(size)
#         if not self.cumulative:
#             raise MemoryError('Integrator memory block not allocated.')

#     @staticmethod
#     def from_network(network):
#         """
#         Instantiate from python network.

#         Args:

#             network (Network)

#         Returns:

#             c_ssa (cSSA)

#         """
#         return cSSA(cSystem.from_network(network))

#     cpdef array evaluate_species_rates(self,
#                                        array states,
#                                        array inputs,
#                                        array cumulative):
#         """
#         Evaluates and returns rate of change for all species.

#         Args:

#             states (array[unsigned int]) - state values

#             inputs (array[double]) - input values

#             cumulative (array[double]) - integrator values

#         Returns:

#             rates (array[double]) - species rates, e.g. dX/dt

#         """
#         return self.system.c_evaluate_species_rates(states, inputs, cumulative)

#     cdef void set_states(self, array x) nogil:
#         """ Set state values. """
#         cdef unsigned int index
#         for index in xrange(self.system.N):
#             self.states[index] = x.data.as_uints[index]

#     cdef void set_inputs(self, array x) nogil:
#         """ Set input values. """
#         cdef unsigned int index
#         for index in xrange(self.system.I):
#             self.inputs[index] = x.data.as_doubles[index]

#     cdef void set_cumulative(self, array x) nogil:
#         """ Set integrator values. """
#         cdef unsigned int index
#         for index in xrange(self.system.N):
#             self.cumulative[index] = x.data.as_doubles[index]

#     cdef void set_rxn_order(self, double* rates):
#         """
#         Order reactions by reaction rate.

#         Args:

#             rates (double*) - reaction rates

#         """
#         cdef unsigned int index = 0
#         cdef unsigned int rxn
#         cdef np.ndarray[double, ndim=1] rates_array
#         cdef np.ndarray[unsigned int, ndim=1] order

#         # store rates as numpy array and get sorting index
#         rates_array = np.asarray(<double[:self.system.M]> rates)
#         order = np.argsort(rates_array).astype(np.uint32)[::-1]

#         # copy to reaction order
#         for index in xrange(self.system.M):
#             self.rxn_order[index] = order[index]

#     cpdef tuple run(self,
#                     unsigned int[::1] ic,
#                     cSignalType signal,
#                     double[::1] integrator_ic,
#                     double dt=1.,
#                     double duration=100):
#         """
#         Python interface for stochastic simulation.

#         Args:

#             ic (int[:]) - initial state values

#             signal (cSignalType) - function returning input values

#             integrator_ic (int[:]) - initial integrator values

#             dt (double) - sampling interval

#             duration (double) - simulation length

#         Returns:

#             times (np.ndarray[double]) - timepoints, length T

#             states (np.ndarray[long]) - interpolated state values, shaped (N,T)

#         """

#         # initialize times and state lists, simulation counters
#         self.set_states(array('I', ic))
#         self.set_cumulative(array('d', integrator_ic))

#         # initialize input
#         self.null_input = 0
#         if signal is None:
#             self.null_input = 1
#             signal = cSignal(0.)
#         self.set_inputs(signal.get_signal(0))

#         # initialize all rates and sort order
#         self.system.R.update_all(self.states, self.inputs, self.cumulative)
#         self.set_rxn_order(self.system.get_rxn_rates())

#         # preallocate regular states array to record simulation history
#         cdef unsigned int num_timepoints = <unsigned int>ceil(duration/dt)
#         rstates = np.empty((self.system.N, num_timepoints), dtype=np.uint32)
#         self.rstates = array('I', rstates.flatten())

#         # run stochastic simulation
#         self.c_run(signal=signal, dt=dt, duration=duration)

#         #return numpy arrays
#         cdef np.ndarray times = np.arange(0, duration, dt)
#         cdef np.ndarray states = np.frombuffer(self.rstates, dtype=np.uint32).reshape(self.system.N, num_timepoints)

#         return times, states

#     cdef void c_run(self,
#                     cSignalType signal,
#                     double dt=1.,
#                     double duration=100) nogil:
#         """
#         Run Gillespie SSA in pure cython.

#         Args:

#             signal (cSignalType) - function returning input values

#             dt (double) - sampling interval

#             duration (double) - simulation length

#         """

#         # declare variables for time management
#         cdef unsigned int index
#         cdef unsigned int t_index = 0
#         cdef unsigned int s_index
#         cdef double t = 0.
#         cdef double threshold = 0.
#         cdef unsigned int num_timepoints = <unsigned int>ceil(duration/dt)

#         # declare items used throughout simulation
#         cdef unsigned int rxn = 0
#         cdef double tau

#         # declare random number
#         cdef double rfloat

#         # initialize input
#         cdef bint changed
#         if self.null_input == 0:
#             signal.reset()

#         # ================================================================
#         # BEGIN SIMULATION
#         # ================================================================
#         while t < duration:

#             # update stored state values
#             while t >= threshold:
#                 for s_index in xrange(self.system.N):
#                     self.rstates.data.as_uints[s_index*num_timepoints+t_index] = self.states[s_index]
#                 threshold += dt
#                 t_index += 1
#                 #self.set_rxn_order(self.system.R.rates)

#             # update input value
#             if self.null_input == 0:

#                 # update input value
#                 signal.update(t)

#                 # check if input changed and input rates accordingly
#                 for index in xrange(self.system.I):
#                     changed = signal.compare_value(self.inputs, index)
#                     if changed == 1:
#                         self.inputs[index] = signal.value.data.as_doubles[index]
#                         self.system.R.update_after_input_change(self.states,
#                                                                self.inputs,
#                                                                self.cumulative,
#                                                                index)

#             # update reaction rates
#             self.system.R.update_after_rxn_fired(self.states,
#                                                 self.inputs,
#                                                 self.cumulative,
#                                                 rxn)

#             # if total rate is zero, keep stepping until input changes
#             if self.system.R.total_rate == 0:

#                 # if there is no input, jump to end
#                 if self.null_input == 1:
#                     break
#                 else:
#                     # skip to next change in input
#                     changed = 0
#                     while t <= duration:
#                         signal.update(t)
#                         changed = signal.compare_all(self.inputs)
#                         if changed == 1:
#                             break
#                         else:
#                             t += dt
#                     continue

#             # choose a reaction
#             rfloat = rand()/(RAND_MAX*1.0)
#             tau = get_timestep(self.system.R.total_rate,
#                                rfloat)
#             rxn = choose_rxn(self.rxn_order,
#                              self.system.R.rates,
#                              self.system.M,
#                              self.system.R.total_rate,
#                              rfloat)

#             # fire reaction
#             self.fire_reaction(rxn, 1, self.states)

#             # increment time and update cumulative state values
#             t += tau
#             if self.integrate == 1:
#                 self.update_cumulative(self.states, self.cumulative, tau)

#         # ================================================================
#         # END SIMULATION
#         # ================================================================

#         # interpolate any later values
#         while threshold < duration:
#             for s_index in xrange(self.system.N):
#                 self.rstates.data.as_uints[s_index*num_timepoints+t_index] = self.states[s_index]
#             threshold += dt
#             t_index += 1

#     cdef unsigned int choose_rxn(self,
#                                  unsigned int *order,
#                                  double *rxn_rates,
#                                  double total_rate,
#                                  double rfloat) nogil:
#         """
#         Select reaction from given pre-sorted rates (faster).

#         Args:

#             order (unsigned int*) - reaction sort indices

#             rxn_rates (double*) - reaction rates

#             total_rate (double) - total reaction rate

#             rfloat (double) - random float on [0, 1) interval

#         Returns:

#             rxn (unsigned int) - reaction index


#         """
#         return choose_rxn(order, rxn_rates, self.system.M, total_rate, rfloat)

#     cdef array get_input_value(self,
#                                cSignalType input_function,
#                                double t):
#         """
#         Returns input values for a specified time.

#         Args:

#             input_function (cSignalType) - signal generating function

#             t (double) - time

#         Returns:

#             inputs (array[double]) - signal values

#         """
#         return input_function.get_signal(t)

#     cdef void fire_reaction(self,
#                             unsigned int rxn,
#                             unsigned int extent,
#                             unsigned int* states) nogil:
#         """
#         Fire a specified reaction by updating state values.

#         Args:

#             rxn (unsigned int) - reaction index

#             extent (unsigned int) - reaction extent

#             states (unsigned int*) - current state values

#         """
#         cdef unsigned int N = self.system.S.lengths[rxn]
#         cdef unsigned int index = self.system.S.index[rxn]
#         cdef unsigned int count, species
#         cdef int coefficient

#         # update each state
#         for count in xrange(N):
#             species = self.system.S.species[index]
#             coefficient = self.system.S.coefficients[index]
#             states[species] += (coefficient * extent)
#             index += 1

#     cdef void update_cumulative(self,
#                                 unsigned int* states,
#                                 double* cumulative,
#                                 double tau) nogil:
#         """

#         Update state integrator values.

#         Args:

#             states (unsigned int*) - state values

#             cumulative (double*) - integrator values

#             tau (double) - time step

#         """
#         cdef unsigned int i
#         for i in xrange(self.system.N):
#             cumulative[i] += (tau * states[i])
