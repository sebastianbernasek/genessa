import numpy as np
from copy import deepcopy

# intra-package python imports
from ..kinetics.hill import Repressor
from ..kinetics.coupling import Coupling
from ..models.coupled import CoupledCell, CoupledCells


class Oscillator(CoupledCell):
    """
    Individual oscillator based on a Drosophila circadian clock model.

    Attributes:

        p (dict) - default parameter values stored as {name: value} pairs

    Inherited Attributes:

        transcripts (dict) - {name: node_id} pairs

        proteins (dict) - {name: node_id} pairs

        phosphorylated (dict) - {name: node_id} pairs

        nodes (np.ndarray) - vector of node indices

        node_key (dict) - {state dimension: node id} pairs

        reactions (list) - list of reaction objects

        stoichiometry (np.ndarray) - stoichiometric coefficients, (N,M)

        N (int) - number of nodes

        M (int) - number of reactions

        I (int) - number of inputs

    """

    def __init__(self, transcription=False, omega=1):
        """
        Instantiate individual oscillator.

        Args:

            transcription (bool) - if True, add decoupled transcription

            omega (float) - concentration scaling factor

        """

        super().__init__()
        p = self.get_default_parameters(omega)
        p = self.add_parameter_names(p)
        self.p = p

        # add genes
        self.add_genes(('P0',), k=p['k_sP'], g1=p['k_d'], g2=p['k_d'])
        self.add_genes(('T0',), k=p['k_sT'], g1=p['k_d'], g2=p['k_d'])

        # add enzymatic transcript degradation
        self.add_transcript_degradation('P0', 'P0', k=p['v_mP'], Kd=p['K_mP'])
        self.add_transcript_degradation('T0', 'T0', k=p['v_mT'], Kd=p['K_mT'])

        # add phosphorylated states
        self.add_phosphorylation('P0', kf=p['V_1P'], Kf=p['K_1P'], kr=p['V_2P'], Kr=p['K_2P'], g=p['k_d'], name='P1')
        self.add_phosphorylation('P1', kf=p['V_3P'], Kf=p['K_3P'], kr=p['V_4P'], Kr=p['K_4P'], g=p['k_d'], name='P2')
        self.add_phosphorylation('T0', kf=p['V_1T'], Kf=p['K_1T'], kr=p['V_2T'], Kr=p['K_2T'], g=p['k_d'], name='T1')
        self.add_phosphorylation('T1', kf=p['V_3T'], Kf=p['K_3T'], kr=p['V_4T'], Kr=p['K_4T'], g=p['k_d'], name='T2')

        # add enzymatic protein degradation
        self.add_protein_degradation('P2', 'P2', k=p['v_dP'], Kd=p['K_dP'], modulation=None)
        self.add_protein_degradation('T2', 'T2', k=p['v_dT'], Kd=p['K_dT'], modulation=(0, 2))

        # add dimerization and translocation
        self.add_dimer('T2', 'P2', kf=p['k3'], kr=p['k4'], g=p['k_dC'], name='C')
        self.add_translocation('C', kf=p['k1'], kr=p['k2'], g=p['k_dN'], name='nC')

        # add transcription reactions
        self.add_transcription('T0', k=p['v_sT'], coupled=[], a=0, w=0, rep='nC', k_m=p['K_IT'], n=p['n'])

        # add decoupled transcription
        if transcription:
            self.add_transcription('P0', k=p['v_sP'], coupled=[], a=0, w=0, rep='nC', k_m=p['K_IP'], n=p['n'])

    @staticmethod
    def add_parameter_names(p):
        for k, v in p.items():
            p[k] = (v, k)
        return p

    @staticmethod
    def get_default_parameters(omega=1):
        """
        Returns dictionary of default parameter values.

        Args:

            omega (float) - concentration scaling factor

        Returns:

            parameters (dict) - {parameter_name: parameter_value} pairs

        """

        return dict(

            # transcriptional repression
            n = 4,
            v_sP = 1.*omega, K_IP = 1.*omega,
            v_sT = 1.*omega, K_IT = 1.*omega,

            # enzymatic transcript degradation
            v_mP = 0.7*omega, K_mP = 0.2*omega,
            v_mT = 0.7*omega, K_mT = 0.2*omega,

            # translation
            k_sP = 0.9, k_sT = 0.9,

            # phosphorylation
            V_1P = 8.*omega, V_2P = 1.*omega, V_3P = 8.*omega, V_4P = 1.*omega,
            V_1T = 8.*omega, V_2T = 1.*omega, V_3T = 8.*omega, V_4T = 1.*omega,
            K_1P = 2.*omega, K_2P = 2.*omega, K_3P = 2.*omega, K_4P = 2.*omega,
            K_1T = 2.*omega, K_2T = 2.*omega, K_3T = 2.*omega, K_4T = 2.*omega,

            # enzymatic protein degradation
            v_dP = 2.*omega, K_dP = 0.2*omega,
            v_dT = 2.*omega, K_dT = 0.2*omega,

            # protein decay
            k_d = 0.01, k_dC = 0.01, k_dN = 0.01,

            # dimerization
            k3 = 1.2/omega, k4 = 0.6,

            # nuclear translocation
            k1 = 0.6, k2 = 0.2)


class CoupledOscillators(CoupledCells):
    """
    Collection of coupled cells.

    Inherited Attributes:

        template (CoupledCell) - template for cell population

        replicates (int) - number of cells in population

        transcripts (dict) - {name: node_id} pairs

        proteins (dict) - {name: node_id} pairs

        phosphorylated (dict) - {name: node_id} pairs

        nodes (np.ndarray) - vector of node indices

        node_key (dict) - {state dimension: node id} pairs

        reactions (list) - list of reaction objects

        stoichiometry (np.ndarray) - stoichiometric coefficients, (N,M)

        N (int) - number of nodes

        M (int) - number of reactions

        I (int) - number of inputs

    """

    def __init__(self, omega=1, replicates=1):
        """
        Instantiate population of coupled oscillators.

        Args:

            omega (float) - concentration scaling factor

            replicates (int) - number of oscillators in population

        """

        # instantiate template oscillator
        oscillator = Oscillator(omega=omega)

        # intantiate population
        super().__init__(oscillator, replicates=replicates)

    def add_coupling(self,
                     adjacency,
                     gene='P0',
                     k=None,
                     a=0,
                     w=0,
                     rep='nC',
                     k_m=None,
                     n=None):
        """
        Add coupling from an adjacency matrix.

        Args:

            adjacency (np.ndarray[bool]) - adjacency matrix

            gene (str) - name of gene being transcribed

            k (float) - transcription rate constant

            a (float) - coupling strength

            w (float) - edge weight

            rep (str) - name of protein that represses transcription

            k_m (float) - michaelis constant for repressor

            n (float) - hill coefficient for repressor

        """

        # store a and w names
        if type(a) in (int, float, np.float64, np.int64):
            a = (a, 'a')
        if type(w) in (int, float, np.float64, np.int64):
            w = (w, 'w')

        # use default rate parameters if none provided
        if k is None:
            k = self.template.p['v_sP']
        if k_m is None:
            k_m = self.template.p['K_IP']
        if n is None:
            n = self.template.p['n']

        # store parameters as keyword arguments
        kwargs = dict(gene=gene, k=k, a=a, w=w, rep=rep, k_m=k_m, n=n)

        # add coupling to each cell in the population
        for cell, row in enumerate(adjacency):
            coupled = row.nonzero()[0]
            self.add_transcription(cell, coupled=coupled, **kwargs)

        # add equivalent synthesis reaction to the template cell
        self.template.add_transcription(coupled=[], **kwargs)
