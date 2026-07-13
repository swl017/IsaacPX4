#!/usr/bin/env bash
# ===========================================================================
#  Launch the IsaacPX4 sim-stack container (GPU + X11 + host network).
#
#  Usage:
#    ./run-simstack.sh                 # interactive bash shell in the container
#    ./run-simstack.sh --build         # (re)build the image first, then shell
#    ./run-simstack.sh <cmd...>        # run a command, e.g.:
#        ./run-simstack.sh isaaclab -p /home/usrg/IsaacPX4/px4_multi_world.isaac.py
#        ./run-simstack.sh tmuxp load /home/usrg/IsaacPX4/tmux/isaac_px4.tmuxp.yaml
#
#  Inside the container everything is at its host path (/home/usrg/IsaacPX4/...);
#  the gimbal_stabilizer overlay is auto-sourced via /root/.bashrc.
# ===========================================================================
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

COMPOSE="docker compose -f docker-compose.yaml"

# --- optional build ---------------------------------------------------------
if [[ "${1:-}" == "--build" ]]; then
    shift
    echo "[run-simstack] building image..."
    $COMPOSE build simstack
fi

# --- image present? ---------------------------------------------------------
if ! docker image inspect isaacpx4-simstack >/dev/null 2>&1; then
    echo "[run-simstack] image 'isaacpx4-simstack' not found. Build it with:" >&2
    echo "    ./run-simstack.sh --build" >&2
    exit 1
fi

# --- X11 authorization ------------------------------------------------------
if [[ -z "${DISPLAY:-}" ]]; then
    echo "[run-simstack] WARNING: \$DISPLAY is empty — the GUI viewport won't show."
    echo "               Run from a desktop session, or launch Isaac Sim headless"
    echo "               (append: --/app/window/hideUi=true --no-window)."
else
    # Let the container's root user talk to the host X server.
    if command -v xhost >/dev/null 2>&1; then
        xhost +local:root >/dev/null 2>&1 || true
        trap 'xhost -local:root >/dev/null 2>&1 || true' EXIT
    fi
    echo "[run-simstack] DISPLAY=$DISPLAY (X11 authorized for local root)"
fi

# --- run --------------------------------------------------------------------
# `run --rm` gives a fresh throwaway container each time; host networking means
# no port mapping is needed.
#
#   No args  -> interactive bash. It gets a TTY, so /root/.bashrc runs fully
#               (its `[ -z "$PS1" ] && return` guard passes) and the ROS2 +
#               gimbal_stabilizer overlay + isaaclab aliases are all active.
#
#   With args -> non-interactive `bash -c`, which SKIPS .bashrc. So we source
#               the ROS2 + gimbal overlay explicitly first. Use full paths for
#               Isaac tools (aliases don't expand under `-c`): the python
#               interpreter is /workspace/isaaclab/_isaac_sim/python.sh and the
#               launcher is /workspace/isaaclab/isaaclab.sh (ISAACLAB_PATH is set).
PREAMBLE='source /opt/ros/humble/setup.bash 2>/dev/null; \
source /home/usrg/IsaacPX4/ros2_ws/install/setup.bash 2>/dev/null;'

if [[ $# -eq 0 ]]; then
    exec $COMPOSE run --rm simstack
else
    exec $COMPOSE run --rm simstack -c "$PREAMBLE $*"
fi
