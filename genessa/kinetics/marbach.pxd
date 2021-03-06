from cpython.array cimport array


cdef inline unsigned int get_binary_repr_size(unsigned int x) nogil:
        """ Get highest dimension of binary representation. """
        cdef unsigned int n = 0
        while x // (2**(n+1)) > 0:
            n += 1
        return n + 1


cdef class cRegulatoryModule:

    # attributes
    cdef unsigned int M
    cdef array nA
    cdef array nD
    cdef array bindsAsComplex
    cdef array k
    cdef array n
    cdef array species_ind
    cdef array species
    cdef array n_active_species
    cdef array xi
    cdef array activation
    cdef cRxnMap rxn_map

    # methods
    @staticmethod
    cdef cRegulatoryModule get_blank_cRegulatoryModule(unsigned int M)

    @staticmethod
    cdef cRegulatoryModule from_list(list rxns,
                                     dict rxn_map)

    cdef double set_fractional_activation(self,
        unsigned int mod,
        unsigned int *states) nogil

    cdef void set_activation(self,
        unsigned int mod,
        unsigned int *states) nogil

    cdef double get_activation(self,
        unsigned int mod) nogil

    cdef void update(self,
        unsigned int *states,
        unsigned int fired) nogil

    cdef double c_evaluate_activation(self,
        double *states,
        unsigned int mod) nogil


cdef class cTranscription:

    # attributes
    cdef unsigned int M
    cdef array k
    cdef array alpha
    cdef array alpha_wt
    cdef array alpha_ind
    cdef array num_alpha
    cdef cRegulatoryModule modules_obj
    cdef array modules_ind
    cdef array num_modules
    cdef array inputs_ind
    cdef array num_inputs
    cdef array inputs
    cdef array input_dependence

    # methods
    @staticmethod
    cdef cTranscription get_blank_cTranscription(unsigned int M)

    @staticmethod
    cdef cTranscription from_list(list rxns,
                                  dict rxn_map)

    cdef void apply_perturbation(self,
        unsigned int rxn,
        double ptb) nogil

    cdef void remove_perturbation(self,
        unsigned int rxn) nogil

    cdef double get_activation(self,
        unsigned int rxn) nogil

    cdef double get_rate_modifier(self,
        unsigned int rxn,
        double *inputs) nogil

    cdef double evaluate_rxn_rate(self,
        unsigned int rxn) nogil

    cdef double c_evaluate_rate(self,
        unsigned int rxn,
        double *states) nogil


ctypedef void (*cSetActivation)(cRegulatoryModule,
                                unsigned int,
                                unsigned int*) nogil


cdef class cRxnMap:

    # attributes
    cdef array ind, lengths, values

    # methods
    cdef void app(self,
                  cRegulatoryModule mod_obj,
                  unsigned int key,
                  cSetActivation f,
                  unsigned int *states) nogil
