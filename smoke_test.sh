#!/bin/bash
set -eux -o pipefail
SOURCE_DIR=$(cd $(dirname $0) && pwd)

# This is meant to be run in either a docker image or in a Mac. This assumes an
# environment that will be teared down after execution is finishes, so it will
# probably mess up what environment it runs in.

# This is now only meant to be run in CircleCI, after calling the
# .circleci/scripts/binary_populate_env.sh . You can call this manually if you
# make sure all the needed variables are still populated.

# Function to retry functions that sometimes timeout or have flaky failures
retry () {
    $*  || (sleep 1 && $*) || (sleep 2 && $*) || (sleep 4 && $*) || (sleep 8 && $*)
}

# Use today's date if none is given
if [[ -z "${DATE:-}" || "${DATE:-}" == 'today' ]]; then
    DATE="$(date +%Y%m%d)"
fi

# DESIRED_PYTHON is in format 2.7m?u?
# DESIRED_CUDA is in format cu80 (or 'cpu')
# DESIRED_DEVTOOLSET should be either 'devtoolset3' or 'devtoolset7'

# Generate M.m formats for CUDA and Python versions
if [[ "$DESIRED_CUDA" != cpu ]]; then
  cuda_dot="$(echo $DESIRED_CUDA | tr -d 'cpu')"
  if [[ "${#cuda_dot}" == 2 ]]; then
    cuda_dot="${cuda_dot:0:1}.${cuda_dot:1}"
  else
    cuda_dot="${cuda_dot:0:2}.${cuda_dot:2}"
  fi
fi
py_dot="${DESIRED_PYTHON:0:3}"

# Generate "long" python versions cp27-cp27mu
py_long="cp${DESIRED_PYTHON:0:1}${DESIRED_PYTHON:2:1}-cp${DESIRED_PYTHON:0:1}${DESIRED_PYTHON:2}"

# Determine package name
if [[ "$PACKAGE_TYPE" == 'libtorch' ]]; then
  if [[ "$(uname)" == Darwin ]]; then
    libtorch_variant='macos'
  elif [[ -z "${LIBTORCH_VARIANT:-}" ]]; then
    echo "No libtorch variant given. This smoke test does not know which zip"
    echo "to download."
    exit 1
  else
    libtorch_variant="$LIBTORCH_VARIANT"
  fi
  package_name="libtorch-$libtorch_variant-${NIGHTLIES_DATE_PREAMBLE}${DATE}.zip"
elif [[ "$PACKAGE_TYPE" == *wheel ]]; then
  package_name='torch-nightly'
elif [[ "$DESIRED_CUDA" == 'cpu' && "$(uname)" != 'Darwin' ]]; then
  package_name='pytorch-nightly-cpu'
else
  package_name='pytorch-nightly'
fi
package_name_and_version="${package_name}==${NIGHTLIES_DATE_PREAMBLE}${DATE}"

# Switch to the desired python
if [[ "$PACKAGE_TYPE" == 'conda' || "$(uname)" == 'Darwin' ]]; then
  # Create a new conda env in conda, or on MacOS
  conda create -yn test python="$py_dot" && source activate test
  retry conda install -yq future numpy protobuf six
else
  export PATH=/opt/python/${py_long}/bin:$PATH
  retry pip install -q future numpy protobuf six
fi

# Switch to the desired CUDA if using the conda-cuda Docker image
if [[ "$PACKAGE_TYPE" == 'conda' ]]; then
  rm -rf /usr/local/cuda || true
  if [[ "$DESIRED_CUDA" != 'cpu' ]]; then
    ln -s "/usr/local/cuda-${cuda_dot}" /usr/local/cuda
    export CUDA_VERSION=$(ls /usr/local/cuda/lib64/libcudart.so.*|sort|tac | head -1 | rev | cut -d"." -f -3 | rev) # 10.0.130
    export CUDA_VERSION_SHORT=$(ls /usr/local/cuda/lib64/libcudart.so.*|sort|tac | head -1 | rev | cut -d"." -f -3 | rev | cut -f1,2 -d".") # 10.0
    export CUDNN_VERSION=$(ls /usr/local/cuda/lib64/libcudnn.so.*|sort|tac | head -1 | rev | cut -d"." -f -3 | rev)
  fi
fi

# Print some debugging info
python --version
pip --version
which python
# If you are debugging packages not found then run these commands.
#if [[ "$PACKAGE_TYPE" == 'conda' ]]; then
#  conda search -c pytorch "$package_name"
#elif [[ "$PACKAGE_TYPE" == *wheel ]]; then
#  retry curl "https://download.pytorch.org/whl/nightly/$DESIRED_CUDA/torch_nightly.html" -v
#fi

# Install the package for the requested date
if [[ "$PACKAGE_TYPE" == 'libtorch' ]]; then
  mkdir tmp_libtorch
  pushd tmp_libtorch
  retry curl -o libtorch_zip "https://download.pytorch.org/libtorch/nightly/$DESIRED_CUDA/$package_name"
  unzip -q libtorch_zip
elif [[ "$PACKAGE_TYPE" == 'conda' ]]; then
  if [[ "$DESIRED_CUDA" == 'cpu' ]]; then
    retry conda install -yq -c pytorch "$package_name_and_version"
  else
    retry conda install -yq -c pytorch "cudatoolkit=$CUDA_VERSION_SHORT" "$package_name_and_version"
  fi
else
  if [[ "$DESIRED_DEVTOOLSET" == 'devtoolset7' ]]; then
    pip_url="https://download.pytorch.org/whl/nightly/devtoolset7/$DESIRED_CUDA/torch_nightly.html"
  else
    pip_url="https://download.pytorch.org/whl/nightly/$DESIRED_CUDA/torch_nightly.html"
  fi
  retry pip install "$package_name_and_version" \
      -f "$pip_url" \
      --no-cache-dir \
      --no-index \
      -q
fi

# Check that all conda features are working
if [[ "$PACKAGE_TYPE" == 'conda' ]]; then
  # Check that conda didn't change the Python version out from under us. Conda
  # will do this if it didn't find the requested package for the current Python
  # version and if nothing else has been installed in the current env.
  if [[ -z "$(python --version 2>&1 | grep -o $py_dot)" ]]; then
    echo "The Python version has changed to $(python --version)"
    echo "Probably the package for the version we want does not exist"
    echo '(conda will change the Python version even if it was explicitly declared)'
    exit 1
  fi

  # Check that the CUDA feature is working
  if [[ "$DESIRED_CUDA" == 'cpu' ]]; then
    if [[ -n "$(conda list torch | grep -o cuda)" ]]; then
      echo "The installed package is built for CUDA:: $(conda list torch)"
      exit 1
    fi
  elif [[ -z "$(conda list torch | grep -o cuda$cuda_dot)" ]]; then
    echo "The installed package doesn't seem to be built for CUDA $cuda_dot"
    echo "The full package is $(conda list torch)"
    exit 1
  fi
fi

"${SOURCE_DIR}/check_binary.sh"