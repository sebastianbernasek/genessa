import numpy as np

# intra-package python imports
from ..kinetics.marbach import Transcription
from .cells import Cell


class MarbachCell(Cell):
    """
    Class defines a cell with one or more protein coding genes. Transcriptional kinetics are dictated by the Marbach model.

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

    def add_transcription(self,
                          gene,
                          modules=None,
                          k=1,
                          alpha=None,
                          perturbed=False,
                          labels={},
                          **kwargs):
        """
        Add transcript synthesis reaction.

        Args:

            gene (str) - target gene name

            modules (list) - RegulatoryModule instances

            k (float) - transcription rate constant

            alpha (array like) - alpha values

            perturbed (bool) - if True, rate is subject to perturbation

            labels (dict) - additional labels for reaction

            kwargs: keyword arguments for reaction

        """

        # define reaction name
        labels['name'] = gene+' transcription'

        # define stoichiometry
        stoichiometry = np.zeros(self.nodes.size, dtype=np.int64)
        stoichiometry[self.transcripts[gene]] = 1

        # define synthesis reaction
        rxn = Transcription(stoichiometry,
                            modules,
                            k=k,
                            alpha=alpha,
                            perturbed=perturbed,
                            atp_sensitive=True,
                            carbon_sensitive=True,
                            ribosome_sensitive=False,
                            labels=labels,
                            **kwargs)

        # add reaction
        self.reactions.append(rxn)
