"""Expression counts matrix construction."""
import gzip
import os

import h5py
import numpy as np
import pandas as pd
import polars as pl
import scipy.io
import scipy.sparse


class ExpressionMatrix:
    """Representation of expression matrices."""

    def __init__(self, matrix=None, features=None, cells=None, fname=None, cache=False):
        """Create a matrix.

        Do not use the constructor directly.
        """
        self._matrix = matrix
        self._features = features
        self._cells = cells
        if fname is not None:
            self._fh = h5py.File(fname, 'r')
        self._cache = cache

        if features is not None and cells is not None and matrix is None:
            self._matrix = np.zeros((len(features), len(cells)), dtype=int)

        if features is not None:
            self._s_features = np.argsort(features)
        if cells is not None:
            self._s_cells = np.argsort(cells)

    def __exit__(self):
        """Cleanup."""
        if self._fh is not None:
            self._fh.close()

    @classmethod
    def from_hdf(cls, name, cache=True):
        """Load a matrix from HDF file."""
        return cls(fname=name, cache=cache)

    @classmethod
    def from_tags(cls, df, feature='gene'):
        """Create a matrix from a tags TSV file, or dataframe."""
        if not isinstance(df, pd.DataFrame):
            df = pd.read_csv(
                df,
                index_col=None,
                usecols=['corrected_barcode', 'corrected_umi', feature],
                sep='\t',
                dtype='category')
        df.drop(df.index[df[feature] == '-'], inplace=True)
        df = (
            df.groupby([feature, 'corrected_barcode'], observed=True)
            .nunique()['corrected_umi']
            .reset_index()  # Get feature back to a column
            .pivot(index=feature, columns='corrected_barcode', values='corrected_umi')
        )
        df.fillna(0, inplace=True)
        return cls(
            df.to_numpy(dtype=int),
            df.index.to_numpy(dtype=bytes),
            df.columns.to_numpy(dtype=bytes))

    @classmethod
    def aggregate_hdfs(cls, fnames):
        """Aggregate a set of matrices stored in HDF."""
        if len(fnames) == 1:
            return cls.from_hdf(fnames[0])
        features = set()
        cells = set()
        for fname in fnames:
            ma = cls.from_hdf(fname)
            features.update(ma.features)
            cells.update(ma.cells)

        full_matrix = cls(
            features=np.array(list(features)), cells=np.array(list(cells)))
        for fname in fnames:
            ma = cls.from_hdf(fname)
            full_matrix + ma
        return full_matrix

    @classmethod
    def aggregate_tags(cls, fnames, feature='gene'):
        """Aggregate a set of tags files."""
        if len(fnames) == 1:
            return cls.from_tags(fnames[0])
        for fname in fnames:
            ma = ExpressionMatrix.from_tags(fname, feature=feature)
            ma.to_hdf(f"{fname}.hdf")
        hdfs = [f"{fname}.hdf" for fname in fnames]
        return cls.aggregate_hdfs(hdfs)

    def to_hdf(self, fname):
        """Save matrix to HDF."""
        with h5py.File(fname, 'w') as fh:
            fh['cells'] = self.cells
            fh['features'] = self.features
            fh['matrix'] = self.matrix

    def to_mex(self, fname, feature_type="Gene Expression", feature_ids=None):
        """Export to MEX folder."""
        os.mkdir(fname)
        # barcodes, write bytes directly
        with gzip.open(os.path.join(fname, "barcodes.tsv.gz"), 'wb') as fh:
            for bc in self.cells:
                fh.write(bc)
                fh.write("-1\n".encode())
        # features, convert to str, write as text
        features = self.tfeatures
        if feature_ids is None:
            feature_ids = {x: f"unknown_{i:05d}" for i, x in enumerate(features)}
        with gzip.open(os.path.join(fname, "features.tsv.gz"), 'wt') as fh:
            for feat in features:
                fh.write(f"{feature_ids[feat]}\t{feat}\t{feature_type}\n")
        # matrix as bytes
        with gzip.open(os.path.join(fname, "matrix.mtx.gz"), 'wb') as fh:
            coo = scipy.sparse.coo_matrix(self.matrix)
            scipy.io.mmwrite(
                fh, coo,
                comment=(
                    'metadata_json: {'
                    '"software_version": "ont-single-cell",'
                    '"format_version": 2}'))

    # TODO: could store feature type in class
    def to_tsv(self, fname, index_name):
        """Write matrix to tab-delimiter file."""
        self.write_matrix(
            fname, self.matrix, self.tfeatures, self.tcells, index_name=index_name)

    @property
    def features(self):
        """An array of feature names."""
        if self._features is not None:
            return self._features
        elif self._fh is not None:
            features = self._fh['features'][()]
            if self._cache:
                self._features = features
            return features
        else:
            raise RuntimeError("Matrix not initialized.")

    @property
    def cells(self):
        """An array of cell names."""
        if self._cells is not None:
            return self._cells
        elif self._fh is not None:
            cells = self._fh['cells'][()]
            if self._cache:
                self._cells = cells
            return cells
        else:
            raise RuntimeError("Matrix not initialized.")

    @property
    def tcells(self):
        """A copy of the cell names as a text array."""
        return np.array(
            [x.decode() for x in self.cells], dtype=str)

    @property
    def tfeatures(self):
        """A copy of the feature names as a text array."""
        return np.array(
            [x.decode() for x in self.features], dtype=str)

    @property
    def matrix(self):
        """Expression matrix array."""
        if self._matrix is not None:
            return self._matrix
        elif self._fh is not None:
            matrix = self._fh['matrix'][()]
            if self._cache:
                self._matrix = matrix
            return matrix
        else:
            raise RuntimeError("Matrix not initialized.")

    @property
    def mean_expression(self):
        """The mean expression of features per cell."""
        return self.matrix.mean(axis=0)

    def normalize(self, norm_count):
        """Normalize total cell weight to fixed cell count."""
        # cell_count / cell_total = X / <norm_count>
        total_per_cell = np.sum(self.matrix, axis=0)
        scaling = norm_count / total_per_cell
        self._matrix = np.multiply(self.matrix, scaling, dtype=float)
        return self

    def remove_features(self, threshold):
        """Remove features that are present in few cells."""
        n_cells = np.count_nonzero(self.matrix, axis=1)
        mask = n_cells >= threshold
        self._matrix = self.matrix[mask]
        self._features = self.features[mask]
        return self

    def remove_cells(self, threshold):
        """Remove cells with few features present."""
        n_features = np.count_nonzero(self.matrix, axis=0)
        mask = n_features >= threshold
        self._matrix = self.matrix[:, mask]
        self._cells = self.cells[mask]
        return self

    def remove_cells_and_features(self, cell_thresh, feature_thresh):
        """Remove cells and features simultaneously.

        The feature and cell removal methods do not commute, this
        method provide a more uniform handling of cell and feature
        filtering.
        """
        n_features = np.count_nonzero(self.matrix, axis=0)
        cell_mask = n_features >= cell_thresh
        self._cells = self.cells[cell_mask]

        n_cells = np.count_nonzero(self.matrix, axis=1)
        feat_mask = n_cells >= feature_thresh
        self._features = self.features[feat_mask]

        self._matrix = self.matrix[feat_mask][:, cell_mask]
        return self

    def remove_skewed_cells(self, threshold, prefixes, fname=None, label=None):
        """Remove cells with overabundance of feature class."""
        sel = self.find_features(prefixes)
        sel_total = self.matrix[sel].sum(axis=0, dtype=float)
        total = self.matrix.sum(axis=0, dtype=float)
        sel_total /= total
        mask = sel_total <= threshold
        if fname is not None:
            self.write_matrix(
                fname, 100 * sel_total, self.tcells, [label], index_name="CB")
        self._matrix = self.matrix[:, mask]
        self._cells = self.cells[mask]
        return self

    def find_features(self, prefixes, inverse=False):
        """Find features by name prefix."""
        sel = np.array([], dtype=int)
        feat = self.tcells
        for pre in prefixes:
            sel = np.union1d(sel, np.argwhere(np.char.find(feat, pre) > -1))
        if inverse:
            sel = np.setdiff1d(np.arange(len(self.features)), sel)
        return sel

    def remove_unknown(self, key="-"):
        """Remove the "unknown" feature."""
        mask = self.features == "-".encode()
        self._matrix = self.matrix[~mask]
        self._features = self.features[~mask]

    def log_transform(self):
        """Transform expression matrix to log scale."""
        np.log1p(self.matrix, out=self.matrix)
        self._matrix /= np.log(10)
        return self

    @staticmethod
    def write_matrix(fname, matrix, index, col_names, index_name="feature"):
        """Write a matrix (or vector) to TSV.

        :param fname: filename.
        :param matrix: matrix to write.
        :param index: index column.
        :param col_names: names for matrix columns.
        :param index_name: name for index column.
        """
        # ok, this is kinda horrible, but its fast
        # I don't think this is actually zero-copy because data is
        # C-contiguous not F-contiguous.
        df = pd.DataFrame(matrix, copy=False, columns=col_names, index=index)
        df.index.rename(index_name, inplace=True)
        df = pl.from_pandas(df, include_index=True)
        df.write_csv(fname, separator="\t")

    def __add__(self, other):
        """Add a second matrix to this matrix."""
        cols = self._s_features[
            np.searchsorted(self.features, other.features, sorter=self._s_features)]
        rows = self._s_cells[
            np.searchsorted(self.cells, other.cells, sorter=self._s_cells)]
        self.matrix[
            np.repeat(cols, len(rows)),
            np.tile(rows, len(cols))] += other.matrix.flatten()
