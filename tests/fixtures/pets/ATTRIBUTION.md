# Pet fixture

Twenty-four photographs from the Oxford-IIIT Pet Dataset, used here to check
that a cat or dog head the face detector reads as a human face cannot veto a
frame. The truth file is `tests/pets_truth.json`; run `./pl check
tests/pets_truth.json`.

The images are unmodified and are redistributed under the dataset's licence,
**Creative Commons Attribution-ShareAlike 4.0**
(https://creativecommons.org/licenses/by-sa/4.0/). They are not covered by
this repository's MIT licence.

Omkar M. Parkhi, Andrea Vedaldi, Andrew Zisserman and C. V. Jawahar,
"Cats and Dogs", IEEE Conference on Computer Vision and Pattern Recognition,
2012. https://www.robots.ox.ac.uk/~vgg/data/pets/

Files are named as in the dataset (`<breed>_<n>.jpg`), so the head boxes in
the dataset's `annotations/xmls/` apply to them directly.
