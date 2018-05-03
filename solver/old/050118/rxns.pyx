# cython: profile=False


"""
TO DO:

1. couple update minor portions of rate on the fly?

"""

cimport cython
cimport rxndiffusion.solver.cython_sum as cython_sum

from rxns cimport cSpeciesDependent, cInputDependent
from rxns cimport cSDRepressor, cIDRepressor
from rxns cimport cPController, cIController
from rxns cimport cMassAction, cHill, cCoupling
from rxns cimport cRxnMap, cRateFunction

import numpy as np
cimport numpy as np
from cpython.array cimport array
from array import array
from functools import reduce
from operator import add


cdef class cSpeciesDependent:
    def __init__(self,
                 int M,
                 double[:] k,
                 long[:] species_ind,
                 long[:] species,
                 double[:] species_dependence):

        # store number of reactions and rate constants
        self.M = M
        self.k = array('d', k)

        # add state dependence
        self.species_ind = array('l', species_ind)
        self.n_active_species = array('l', np.diff(species_ind).astype(int))
        self.species = array('l', species)
        self.species_dependence = array('d', species_dependence)

        # initialize rate vector
        self.rates = array('d', np.zeros(M, dtype=np.float64))

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cdef double get_rate(self, int rxn) nogil:
        """ Get rate of specified reaction """
        return self.rates.data.as_doubles[rxn]

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cdef double get_species_activity(self, int rxn, array states) nogil:
        return <double>self.get_species_activity_product(rxn, states)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cdef int get_species_activity_product(self, int rxn, array states) nogil:
        """ Integrate species activity for specified reaction. """
        cdef int count, n, state
        cdef double k
        cdef int index = self.species_ind.data.as_longs[rxn]
        cdef int N = self.n_active_species.data.as_longs[rxn]
        cdef int activity = 1

        # integrate species activity
        for count in xrange(N):
            state = self.species.data.as_longs[index]
            n = states.data.as_longs[state]
            k = self.species_dependence.data.as_doubles[index]
            if k == 1:
                activity *= n
            elif k == 2:
                activity *= (n*(n-1)/2)
            else:
                activity = 0
            index += 1

        return activity

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cdef double get_species_activity_sum(self, int rxn, array states) nogil:
        """ Integrate species activity for specified reaction. """
        cdef int count, n, state
        cdef double k
        cdef int index = self.species_ind.data.as_longs[rxn]
        cdef int N = self.n_active_species.data.as_longs[rxn]
        cdef double activity = 0

        # integrate species activity
        for count in xrange(N):
            state = self.species.data.as_longs[index]
            n = states.data.as_longs[state]
            k = self.species_dependence.data.as_doubles[index]
            activity += (n * k)
            index += 1

        return activity


cdef class cPController(cSpeciesDependent):

    @staticmethod
    cdef cPController get_blank_cPController():
        cdef np.ndarray xf = np.zeros(1, dtype=np.float64)
        cdef np.ndarray xl = np.zeros(1, dtype=np.int64)
        return cPController(0, xf, xl, xl, xf)

    @staticmethod
    cdef cPController from_list(list rxns):
        """ Instantiate from list of reactions. """
        cdef int M
        cdef np.ndarray k
        cdef np.ndarray species_ind, species, species_dependence

        # if no controllers, return blank
        M = len(rxns)
        if M == 0:
            return cPController.get_blank_cPController()

        # get parameters
        k = np.array([rxn.k[0] for rxn in rxns], dtype=np.float64)

        # get species dependence
        species_ind = np.cumsum([0]+[rxn.num_active_species for rxn in rxns])
        species = np.hstack([rxn.active_species for rxn in rxns])
        species_dependence = np.hstack([rxn._propensity for rxn in rxns])
        return cPController(M, k, species_ind, species, species_dependence)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cdef double get_species_activity(self, int rxn, array states) nogil:
        return self.get_species_activity_sum(rxn, states)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cdef double update(self, int rxn, array states) nogil:
        """ Update rate of specified reaction. """
        cdef double species_activity, rate

        # compute species activities
        species_activity = self.get_species_activity(rxn, states)

        # set rate
        rate = self.k.data.as_doubles[rxn] * species_activity
        if rate < 0:
            rate = 0.

        #self.rates.data.as_doubles[rxn] = rate
        return rate


cdef class cIController(cPController):

    @staticmethod
    cdef cIController get_blank_cIController():
        cdef np.ndarray xf = np.zeros(1, dtype=np.float64)
        cdef np.ndarray xl = np.zeros(1, dtype=np.int64)
        return cIController(0, xf, xl, xl, xf)

    @staticmethod
    cdef cIController from_list(list rxns):
        """ Instantiate from list of reactions. """
        cdef int M
        cdef np.ndarray k
        cdef np.ndarray species_ind, species, species_dependence

        # if no controllers, return blank
        M = len(rxns)
        if M == 0:
            return cIController.get_blank_cIController()

        # get parameters
        k = np.array([rxn.k[0] for rxn in rxns], dtype=np.float64)

        # get species dependence
        species_ind = np.cumsum([0]+[rxn.num_active_species for rxn in rxns])
        species = np.hstack([rxn.active_species for rxn in rxns])
        species_dependence = np.hstack([rxn._propensity for rxn in rxns])
        return cIController(M, k, species_ind, species, species_dependence)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cdef double get_species_activity_sum(self, int rxn, array cumul) nogil:
        """ Integrate cumulative activity for specified reaction. """
        cdef int count, state
        cdef double n, k
        cdef int index = self.species_ind.data.as_longs[rxn]
        cdef int N = self.n_active_species.data.as_longs[rxn]
        cdef double activity = 0

        # integrate species activity
        for count in xrange(N):
            state = self.species.data.as_longs[index]
            n = cumul.data.as_doubles[state]
            k = self.species_dependence.data.as_doubles[index]
            activity += (n * k)
            index += 1

        return activity


cdef class cInputDependent(cSpeciesDependent):
    def __init__(self,
                 int M,
                 double[:] k,
                 long[:] species_ind,
                 long[:] species,
                 double[:] species_dependence,
                 long[:] inputs_ind,
                 long[:] inputs,
                 double[:] input_dependence):

        # add species dependence
        cSpeciesDependent.__init__(self, M, k, species_ind, species, species_dependence)

        # add input dependence
        self.inputs_ind = array('l', inputs_ind)
        self.n_active_inputs = array('l', np.diff(inputs_ind).astype(int))
        self.inputs = array('l', inputs)
        self.input_dependence = array('d', input_dependence)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cdef double get_input_activity(self, int rxn, array inputs) nogil:
        return self.get_input_activity_product(rxn, inputs)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cdef double get_input_activity_product(self, int rxn, array input_values) nogil:
        """ Integrate input activity for specified reaction. """
        cdef int count, dim
        cdef double n, k
        cdef int index = self.inputs_ind.data.as_longs[rxn]
        cdef int I = self.n_active_inputs.data.as_longs[rxn]
        cdef double activity = 1.

        # integrate input activity
        for count in xrange(I):
            dim = self.inputs.data.as_longs[index]
            n = input_values.data.as_doubles[dim]
            k = self.input_dependence.data.as_doubles[index]
            activity *= (n**k)
            index += 1

        return activity

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cdef double get_input_activity_sum(self, int rxn, array input_values) nogil:
        """ Integrate input activity for specified reaction. """
        cdef int count, dim
        cdef double n, k
        cdef int index = self.inputs_ind.data.as_longs[rxn]
        cdef int I = self.n_active_inputs.data.as_longs[rxn]
        cdef double activity = 0.

        # integrate input activity
        for count in xrange(I):
            dim = self.inputs.data.as_longs[index]
            n = input_values.data.as_doubles[dim]
            k = self.input_dependence.data.as_doubles[index]
            activity += (n*k)
            index += 1

        return activity


cdef class cMassAction(cInputDependent):

    @staticmethod
    cdef cMassAction get_blank_cMassAction():
        cdef np.ndarray xf = np.zeros(1, dtype=np.float64)
        cdef np.ndarray xl = np.zeros(1, dtype=np.int64)
        return cMassAction(0, xf, xl, xl, xf, xl, xl, xf)

    @staticmethod
    cdef cMassAction from_list(list rxns):
        """ Instantiate from list of reactions. """

        cdef int M
        cdef np.ndarray k
        cdef np.ndarray species_ind, species, species_dependence
        cdef np.ndarray inputs_ind, inputs, input_dependence

        # return blank if no reactions of this type
        M = len(rxns)
        if M == 0:
            return cMassAction.get_blank_cMassAction()

        # get parameters
        k = np.array([rxn.k[0] for rxn in rxns], dtype=np.float64)

        # get species dependence
        species_ind = np.cumsum([0]+[rxn.num_active_species for rxn in rxns])
        species = np.hstack([rxn.active_species for rxn in rxns])
        species_dependence = np.hstack([rxn._propensity for rxn in rxns])
        species_dependence = species_dependence.astype(np.float64)
        inputs_ind = np.cumsum([0]+[rxn.num_active_inputs for rxn in rxns])
        inputs = np.hstack([rxn.active_inputs for rxn in rxns])
        input_dependence = np.hstack([rxn._input_dependence for rxn in rxns])
        input_dependence = input_dependence.astype(np.float64)
        return cMassAction(M, k, species_ind, species, species_dependence, inputs_ind, inputs, input_dependence)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cdef double update(self, int rxn, array states, array inputs) nogil:
        """ Update rate of specified reaction. """
        cdef double species_activity, input_activity
        cdef double rate

        # compute species activities
        species_activity = self.get_species_activity(rxn, states)
        input_activity = self.get_input_activity(rxn, inputs)

        # set rate
        rate = self.k.data.as_doubles[rxn] * species_activity * input_activity

        #self.rates.data.as_doubles[rxn] = rate
        return rate


cdef class cSDRepressor(cSpeciesDependent):
    def __init__(self,
                 int M,
                 double[:] k_m,
                 double[:] n,
                 long[:] species_ind,
                 long[:] species,
                 double[:] species_dependence):

        # add input/species dependence
        vmax = array('d', np.ones(M, dtype=np.int64))
        cSpeciesDependent.__init__(self, M, vmax, species_ind, species, species_dependence)
        self.k_m = array('d', k_m)
        self.n = array('d', n)

    @staticmethod
    cdef cSDRepressor get_blank_cSDRepressor():
        cdef np.ndarray xf = np.zeros(1, dtype=np.float64)
        cdef np.ndarray xl = np.zeros(1, dtype=np.int64)
        return cSDRepressor(0, xf, xf, xl, xl, xf)

    @staticmethod
    cdef cSDRepressor from_list(list rxns):
        """ Instantiate from list of reactions. """
        cdef int M
        cdef list reps
        cdef np.ndarray k_m, n
        cdef np.ndarray species_ind, species, species_dependence

        # get repressors
        reps = reduce(add, [rxn.repressors for rxn in rxns])

        # if there are no repressors, return empty arrays
        M = len(reps)
        if M == 0:
            return cSDRepressor.get_blank_cSDRepressor()

        # get parameters
        k_m = np.array([rxn.k_m for rxn in reps], dtype=np.float64)
        n = np.array([rxn.n for rxn in reps], dtype=np.float64)

        # get species dependence
        species_ind = np.cumsum([0]+[rxn.num_active_substrates for rxn in reps])
        species = np.hstack([rxn.active_substrates for rxn in reps])
        species_dependence = np.hstack([rxn._propensity for rxn in reps])

        return cSDRepressor(M, k_m, n, species_ind, species, species_dependence)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cdef double get_species_activity(self, int rep, array states) nogil:
        return self.get_species_activity_sum(rep, states)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cdef double get_occupancy(self, int rep, array states) nogil:
        """ Get occupancy by specified repressor. """
        cdef double activity
        cdef double k_m, n
        cdef double occupancy

        # compute species activities
        activity = self.get_species_activity(rep, states)

        # compute occupancy
        k_m = self.k_m.data.as_doubles[rep]
        n = self.n.data.as_doubles[rep]
        occupancy =  (activity**n) / ( (activity**n) + (k_m**n) )

        return occupancy


cdef class cIDRepressor(cInputDependent):
    def __init__(self,
                 int M,
                 double[:] k_m,
                 double[:] n,
                 long[:] species_ind,
                 long[:] species,
                 double[:] species_dependence,
                 long[:] inputs_ind,
                 long[:] inputs,
                 double[:] input_dependence):

        # add input/species dependence
        vmax = array('d', np.ones(M, dtype=np.int64))
        cInputDependent.__init__(self, M, vmax, species_ind, species, species_dependence, inputs_ind, inputs, input_dependence)
        self.k_m = array('d', k_m)
        self.n = array('d', n)

    @staticmethod
    cdef cIDRepressor get_blank_cIDRepressor():
        cdef np.ndarray xf = np.zeros(1, dtype=np.float64)
        cdef np.ndarray xl = np.zeros(1, dtype=np.int64)
        return cIDRepressor(0, xf, xf, xl, xl, xf, xl, xl, xf)

    @staticmethod
    cdef cIDRepressor from_list(list rxns):
        """ Instantiate repressor object from list of reactions. """
        cdef int M
        cdef list reps
        cdef np.ndarray k_m, n
        cdef np.ndarray species_ind, species, species_dependence
        cdef np.ndarray inputs_ind, inputs, input_dependence

        # get repressors
        reps = reduce(add, [rxn.repressors for rxn in rxns])

        # if there are no repressors, return empty arrays
        M = len(reps)
        if M == 0:
            return cIDRepressor.get_blank_cIDRepressor()

        # add parameters
        k_m = np.array([rxn.k_m for rxn in reps], dtype=np.float64)
        n = np.array([rxn.n for rxn in reps], dtype=np.float64)

        # add species dependence
        species_ind =np.cumsum([0]+[rxn.num_active_substrates for rxn in reps])
        species = np.hstack([rxn.active_substrates for rxn in reps])
        species_dependence = np.hstack([rxn._propensity for rxn in reps])
        inputs_ind = np.cumsum([0]+[rxn.num_active_inputs for rxn in reps])
        inputs = np.hstack([rxn.active_inputs for rxn in reps])
        input_dependence = np.hstack([rxn._input_dependence for rxn in reps])

        return cIDRepressor(M, k_m, n, species_ind, species, species_dependence, inputs_ind, inputs, input_dependence)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cdef double get_species_activity(self, int rep, array states) nogil:
        return self.get_species_activity_sum(rep, states)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cdef double get_input_activity(self, int rep, array inputs) nogil:
        return self.get_input_activity_sum(rep, inputs)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cdef double get_occupancy(self, int rep, array states, array inputs) nogil:
        """ Get occupancy by specified repressor. """
        cdef double activity, species_activity, input_activity
        cdef double k_m, n
        cdef double occupancy

        # compute species activities
        species_activity = self.get_species_activity(rep, states)
        input_activity = self.get_input_activity(rep, inputs)
        activity = species_activity + input_activity

        # compute occupancy
        k_m = self.k_m.data.as_doubles[rep]
        n = self.n.data.as_doubles[rep]
        occupancy =  (activity**n) / ( (activity**n) + (k_m**n) )

        return occupancy


cdef class cHill(cIDRepressor):
    def __init__(self,
                 int M,
                 double[:] vmax,
                 double[:] k_m,
                 double[:] n,
                 long[:] species_ind,
                 long[:] species,
                 double[:] species_dependence,
                 long[:] inputs_ind,
                 long[:] inputs,
                 double[:] input_dependence,

                 cIDRepressor repressor_obj,
                 long[:] repressors_ind):

        # add input/species dependence
        cInputDependent.__init__(self, M, vmax, species_ind, species, species_dependence, inputs_ind, inputs, input_dependence)
        self.k_m = array('d', k_m)
        self.n = array('d', n)

        # add repressor data
        self.rep_obj = repressor_obj
        self.repressors_ind = array('l', repressors_ind)
        self.n_repressors = array('l', np.diff(repressors_ind).astype(int))

    @staticmethod
    cdef cHill get_blank_cHill():
        cdef np.ndarray xf = np.zeros(1, dtype=np.float64)
        cdef np.ndarray xl = np.zeros(1, dtype=np.int64)
        cdef cIDRepressor rep = cIDRepressor.get_blank_cIDRepressor()
        return cHill(0, xf, xf, xf, xl, xl, xf, xl, xl, xf, rep, xl)

    @staticmethod
    cdef cHill from_list(list rxns):
        """ Instantiate from list of reactions. """
        cdef int M
        cdef np.ndarray vmax, k_m, n
        cdef np.ndarray species_ind, species, species_dependence
        cdef np.ndarray inputs_ind, inputs, input_dependence
        cdef cIDRepressor repressor_obj
        cdef np.ndarray repressors_ind

        # if no reactions, add blank object
        M = len(rxns)
        if M == 0:
            return cHill.get_blank_cHill()

        # add parameters
        vmax = np.array([rxn.k[0] for rxn in rxns], dtype=np.float64)
        k_m = np.array([rxn.k_m for rxn in rxns], dtype=np.float64)
        n = np.array([rxn.n for rxn in rxns], dtype=np.float64)

        # add species and input dependence
        species_ind = np.cumsum([0]+[rxn.num_active_substrates for rxn in rxns])
        species = np.hstack([rxn.active_substrates for rxn in rxns])
        species_dependence = np.hstack([rxn._propensity for rxn in rxns])
        species_dependence = species_dependence.astype(np.float64)
        inputs_ind = np.cumsum([0]+[rxn.num_active_inputs for rxn in rxns])
        inputs = np.hstack([rxn.active_inputs for rxn in rxns])
        input_dependence = np.hstack([rxn._input_dependence for rxn in rxns])
        input_dependence = input_dependence.astype(np.float64)

        # add repressors
        repressor_obj = cIDRepressor.from_list(rxns)
        repressors_ind = np.cumsum([0]+[len(rxn.repressors) for rxn in rxns])

        return cHill(M, vmax, k_m, n, species_ind, species, species_dependence, inputs_ind, inputs, input_dependence, repressor_obj, repressors_ind)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cdef double get_species_activity(self, int rxn, array states) nogil:
        return self.get_species_activity_sum(rxn, states)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cdef double get_input_activity(self, int rxn, array inputs) nogil:
        return self.get_input_activity_sum(rxn, inputs)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cdef double get_availability(self, int rxn, array states, array inputs)nogil:
        """ Integrate all repressor activity to determine availability. """

        cdef int count
        cdef double occupancy
        cdef double availability = 1
        cdef int index = self.repressors_ind.data.as_longs[rxn]
        cdef int num_repressors = self.n_repressors.data.as_longs[rxn]

        # integrate repressor occupancies (multiplicative)
        for count in xrange(num_repressors):
            occupancy = self.rep_obj.get_occupancy(index, states, inputs)
            availability *= (1-occupancy)
            index += 1

        return availability

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cdef double update(self, int rxn, array states, array inputs) nogil:
        """ Update rate of specified reaction. """
        cdef double activity, species_activity, input_activity
        cdef double vmax, n, k_m
        cdef double availability
        cdef double rate = 1

        # compute species activities
        species_activity = self.get_species_activity(rxn, states)
        input_activity = self.get_input_activity(rxn, inputs)
        activity = species_activity + input_activity

        # compute rate
        vmax = self.k.data.as_doubles[rxn]
        k_m = self.k_m.data.as_doubles[rxn]
        n = self.n.data.as_doubles[rxn]
        rate *=  vmax * (activity**n) / ( (activity**n) + (k_m**n) )

        # apply repressors
        availability = self.get_availability(rxn, states, inputs)
        rate *= availability

        #self.rates.data.as_doubles[rxn] = rate
        return rate


cdef class cCoupling(cSpeciesDependent):
    def __init__(self,
                 int M,
                 double[:] k,
                 double[:] a,
                 double[:] w,

                 long[:] species_ind,
                 long[:] species,
                 double[:] species_dependence,

                 cSDRepressor repressor_obj,
                 long[:] repressors_ind):

        # add input/species dependence
        cSpeciesDependent.__init__(self, M, k, species_ind, species, species_dependence)
        self.a = array('d', a)
        self.w = array('d', w)

        # add repressor data
        self.rep_obj = repressor_obj
        self.repressors_ind = array('l', repressors_ind)
        self.n_repressors = array('l', np.diff(repressors_ind).astype(int))

    @staticmethod
    cdef cCoupling get_blank_cCoupling():
        cdef np.ndarray xf = np.zeros(1, dtype=np.float64)
        cdef np.ndarray xl = np.zeros(1, dtype=np.int64)
        cdef cSDRepressor rep = cSDRepressor.get_blank_cSDRepressor()
        return cCoupling(0, xf, xf, xf, xl, xl, xf, rep, xl)

    @staticmethod
    cdef cCoupling from_list(list rxns):
        """ Instantiate from list of reactions. """
        cdef int M
        cdef np.ndarray k, a, w
        cdef np.ndarray species_ind, species, species_dependence
        cdef cSDRepressor repressor_obj
        cdef np.ndarray repressors_ind

        # if no reactions of this type, add blank
        M = len(rxns)
        if M == 0:
            return cCoupling.get_blank_cCoupling()

        # get parameters
        k = np.array([rxn.k[0] for rxn in rxns], dtype=np.float64)
        a = np.array([rxn.a for rxn in rxns], dtype=np.float64)
        w = np.array([rxn.w for rxn in rxns], dtype=np.float64)

        # add species dependence
        species_ind = np.cumsum([0]+[rxn.num_active_species for rxn in rxns])
        species = np.hstack([rxn.active_species for rxn in rxns])
        species_dependence = np.hstack([rxn._propensity for rxn in rxns])
        species_dependence = species_dependence.astype(np.float64)

        # add repressors
        repressor_obj = cSDRepressor.from_list(rxns)
        repressors_ind = np.cumsum([0]+[len(rxn.repressors) for rxn in rxns])

        return cCoupling(M, k, a, w, species_ind, species, species_dependence, repressor_obj, repressors_ind)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cdef double get_species_activity(self, int rxn, array states) nogil:
        return self.get_species_activity_sum(rxn, states)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cdef double get_availability(self, int rxn, array states) nogil:
        """ Integrate all repressor activity to determine availability. """

        cdef int count
        cdef double occupancy
        cdef double availability = 1
        cdef int index = self.repressors_ind.data.as_longs[rxn]
        cdef int num_repressors = self.n_repressors.data.as_longs[rxn]

        # integrate repressor occupancies (multiplicative)
        for count in xrange(num_repressors):
            occupancy = self.rep_obj.get_occupancy(index, states)
            availability *= (1-occupancy)
            index += 1

        return availability

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cdef double update(self, int rxn, array states) nogil:
        """ Update rate of specified reaction. """
        cdef double coupling
        cdef int N
        cdef double vmax, n, k_m
        cdef double availability
        cdef double rate

        # compute species activities
        coupling = self.get_species_activity(rxn, states)

        # compute rate
        N = self.n_active_species.data.as_longs[rxn]
        k = self.k.data.as_doubles[rxn]
        a = self.a.data.as_doubles[rxn]
        w = self.w.data.as_doubles[rxn]
        rate = k + ((a*w/(1+w*(N-1)))*coupling)

        # apply repressors
        availability = self.get_availability(rxn, states)
        rate *= availability

        # update rate
        if rate < 0:
            rate = 0

        #self.rates.data.as_doubles[rxn] = rate
        return rate

cdef class cRxnMap:

    def __init__(self, adict):
        ind, lengths, values = self.dict_to_array(adict)
        self.ind = array('l', ind)
        self.lengths =  array('l', lengths)
        self.values = array('l', values)

    @staticmethod
    def dict_to_array(adict):
        lengths, values = zip(*[(len(l), l) for l in adict.values()])
        indices = np.insert(np.cumsum(lengths), 0, 0)
        values = np.hstack(values).astype(int)
        return indices, lengths, values

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cdef void app(self, cRateFunction rf, int key, cSetRate f,
                  array states, array inputs, array cumul) nogil:
        cdef int count
        cdef int length = self.lengths.data.as_longs[key]
        cdef int rxn
        cdef int index = self.ind.data.as_longs[key]

        for count in xrange(length):
            rxn = self.values.data.as_longs[index]
            f(rf, rxn, states, inputs, cumul)
            index += 1


cdef class cRateFunction:

    def __init__(self,
                 cCoupling coupling,
                 cMassAction massaction,
                 cHill hill,
                 cIController icontrol,
                 cPController pcontrol,
                 long[:] rxn_types,
                 long[:] rxn_keys,
                 dict rxn_map,
                 dict input_map):

        # store rate objects
        self.coupling = coupling
        self.massaction = massaction
        self.hill = hill
        self.icontrol = icontrol
        self.pcontrol = pcontrol

        # store reaction types and dependencies
        self.M = len(rxn_types)
        self.rxn_types = array('l', rxn_types)
        self.rxn_keys = array('l', rxn_keys)
        self.rxn_map = cRxnMap(rxn_map)
        self.input_map = cRxnMap(input_map)

        # initialize rates array
        self.rates = array('d', np.zeros(self.M, dtype=np.float64))
        self.total_rate = cython_sum.sum_double_arr(self.rates, self.M)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cdef array get_rxn_rates(self):
        """ Get current rate vector. """
        return self.rates

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cdef double evaluate(self, int rxn, array states, array inputs, array cumul) nogil:
        """ Update rate of individual reaction. """

        cdef int rxn_type, rxn_key
        cdef double rate

        # get reaction type
        rxn_type = self.rxn_types.data.as_longs[rxn]
        rxn_key = self.rxn_keys.data.as_longs[rxn]

        # get reaction rate
        if rxn_type == 0:
            rate =self.coupling.update(rxn_key, states)
            #rate = self.coupling.get_rate(rxn_key)

        elif rxn_type == 1:
            rate = self.massaction.update(rxn_key, states, inputs)
            #rate = self.massaction.get_rate(rxn_key)

        elif rxn_type == 2:
            rate = self.hill.update(rxn_key, states, inputs)
            #rate = self.hill.get_rate(rxn_key)

        elif rxn_type == 3:
            rate = self.icontrol.update(rxn_key, cumul)
            #rate = self.icontrol.get_rate(rxn_key)

        elif rxn_type == 4:
            rate = self.pcontrol.update(rxn_key, states)
            #rate = self.pcontrol.get_rate(rxn_key)

        else:
            pass

        return rate

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cdef void set_rate(self, int rxn, array states, array inputs, array cumul) nogil:
        """ Set rate for individual reaction. """
        cdef double old_rate, rate

        # update rxn rate
        rate = self.evaluate(rxn, states, inputs, cumul)
        old_rate = self.rates.data.as_doubles[rxn]

        # update total rate
        self.rates.data.as_doubles[rxn] = rate
        self.total_rate += (rate - old_rate)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cdef void update_input(self, array states, array inputs, array cumul, int dim) nogil:
        """ Update rates for input-dependent reactions that have changed. """
        self.input_map.app(self, dim, self.set_rate, states, inputs, cumul)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cdef void update(self, array states, array inputs, array cumul, int fired) nogil:
        """ Update rates for species-dependent reactions that have changed. """
        self.rxn_map.app(self, fired, self.set_rate, states, inputs, cumul)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cdef void update_all(self, array states, array inputs, array cumul) nogil:
        """ Update all reaction rates. """
        cdef int rxn
        for rxn in xrange(self.M):
            self.set_rate(rxn, states, inputs, cumul)


# ==============================END CYTHON=================================== #


class RateFunction:
    """ Python wrapper for c-based reaction rate computation."""
    def __init__(self, cell):
        """
        Args:
        rxns (list of reaction instances)
        """
        coupling, massaction, hill, icontrol, pcontrol = [], [], [], [], []
        rxn_types = []

        for rxn in cell.reactions:
            if rxn.__class__.__name__ == 'Coupling':
                rxn_types.append(0)
                coupling.append(rxn)
            elif rxn.__class__.__name__ == 'Reaction':
                rxn_types.append(1)
                massaction.append(rxn)
            elif rxn.__class__.__name__ == 'EnzymaticReaction':
                rxn_types.append(2)
                hill.append(rxn)
            elif rxn.__class__.__name__ == 'IntegralController':
                rxn_types.append(3)
                icontrol.append(rxn)
            elif rxn.__class__.__name__ == 'ProportionalController':
                rxn_types.append(4)
                pcontrol.append(rxn)
            else:
                raise ValueError('{} reaction type not recognized.'.format(rxn.__class__.__name__))

        # get rate objects
        coupling = cCoupling.from_list(coupling)
        massaction = cMassAction.from_list(massaction)
        hill = cHill.from_list(hill)
        icontrol = cIController.from_list(icontrol)
        pcontrol = cPController.from_list(pcontrol)

        # get reaction map
        rxn_map = self.get_rxn_map(cell)
        input_map = self.get_input_map(cell)

        # set reaction lists
        rxn_types = np.array(rxn_types, dtype=np.int64)
        rxn_keys = self.get_rxn_keys(rxn_types)

        # instantiate cReactions object
        self.cRateFunction = cRateFunction(coupling, massaction, hill, icontrol, pcontrol, rxn_types, rxn_keys, rxn_map, input_map)

    @staticmethod
    def get_rxn_keys(rxn_types):
        keys = np.zeros_like(rxn_types)
        for rxn_type in np.unique(rxn_types):
            ind = (rxn_types==rxn_type)
            keys[ind] = np.cumsum(ind)[ind]-1
        return keys

    @staticmethod
    def get_propensity_dict(network):
        """ Returns dictionary where keys are states and values are lists of  reaction indices whose propensities depend upon each state. """
        adict = {i: [] for i in range(network.nodes.size)}
        for (i, rxn) in enumerate(network.reactions):

            # store index of reaction i whose propensity depends on state s
            for s in rxn.propensity.nonzero()[0]:
                adict[s].append(i)

            # store index of reaction i whose repression depends on state s
            rxn_type = rxn.__class__.__name__
            if rxn_type in ('EnzymaticReaction', 'Coupling'):
                for repressor in rxn.repressors:
                    for s in repressor.active_substrates:
                        adict[s].append(i)

        return adict

    @classmethod
    def get_rxn_map(cls, network):

        p_dict = cls.get_propensity_dict(network)

        adict = {i: [] for i in range(len(network.reactions))}
        for (i, rxn) in enumerate(network.reactions):
            list_of_lists = [p_dict[s] for s in rxn.stoichiometry.nonzero()[0]]
            alist = reduce(add, list_of_lists)
            adict[i].extend(alist)

        # remove duplicates
        for (k, v) in adict.items():
            adict[k] = list(set(v))

        return adict

    @staticmethod
    def get_input_map(network):
        adict = {i: [] for i in range(network.input_size)}
        for (j, rxn) in enumerate(network.reactions):
            rxn_type = rxn.__class__.__name__
            if rxn_type in ('Coupling', 'SumReaction', 'ProportionalController', 'IntegralController'):
                continue
            for s in rxn.input_dependence.nonzero()[0]:
                adict[s].append(j)
        return adict

    def __call__(self, states, input_value, cumulative):
        """
        Get rate vector from cRateFunction.get_rxn_rate

        Args:
        states (np array, dtype=np.float64)
        input_value (np array, dtype=np.float64)
        """
        return self.get_rxn_rates(states, input_value, cumulative)

    def get_callable(self):
        """ Get callable cRateFunction.get_rxn_rates instance. """
        return self.cRateFunction.get_rxn_rates

    def get_rxn_rates(self, states, input_value, cumulative):
        """
        Call cRateFunction.get_rxn_rate.

        Args:
        states (np array, dtype=np.float64)
        input_value (np array, dtype=np.float64)
        """
        return self.cRateFunction.get_rxn_rates(states, input_value, cumulative)

