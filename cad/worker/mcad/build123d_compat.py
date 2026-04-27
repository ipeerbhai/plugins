"""Compatibility shims for the pinned Build123d/OCP stack used by MCAD.

The package set currently available in this environment pairs Build123d 0.8
with an OCP build that no longer exposes ``TopoDS_Shape.HashCode``. Build123d
still calls that method internally when enumerating topology entities.

We patch in a small fallback before Build123d is imported. ``TopoDS_Shape`` is
already Python-hashable, so modulo the requested upper bound is enough to
preserve Build123d's dictionary bucketing behavior.
"""

from OCP.TopoDS import TopoDS_Shape


if not hasattr(TopoDS_Shape, "HashCode"):
    def _hash_code(self, upper: int) -> int:
        return hash(self) % upper

    TopoDS_Shape.HashCode = _hash_code
