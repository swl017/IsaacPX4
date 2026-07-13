# syntax=docker/dockerfile:1
# ===========================================================================
#  IsaacPX4 full sim-stack image
#  = Isaac Sim + Isaac Lab + ROS2 Humble   (from BASE_IMAGE)
#  + PegasusSimulator (local fork, extension-installed)
#  + PX4-Autopilot SITL (local fork, compiled here)
#  + gimbal_stabilizer  (ROS2 overlay workspace)
#  + world/ (USD scenes) + tmux/ (launch configs)
#
#  PREREQUISITE -- the base image must contain Isaac Sim + ROS2 Humble.
#  Only `isaac-lab-base` (no ROS2) exists locally, so build the ROS2 layer once:
#
#      cd IsaacLab/docker && python container.py start ros2   # -> image "isaac-lab-ros2"
#      # (you can `python container.py stop ros2` afterwards; we only need the image)
#
#  BUILD (from the repo root, so the .dockerignore applies):
#
#      cd /home/usrg/IsaacPX4
#      DOCKER_BUILDKIT=1 docker build -t isaacpx4-simstack .
#
#  If you already have a ROS2-enabled image, skip the prerequisite and pass it:
#      docker build -t isaacpx4-simstack --build-arg BASE_IMAGE=swl017/isaac-lab-iris .
# ===========================================================================
ARG BASE_IMAGE=isaac-lab-ros2

# ---------------------------------------------------------------------------
# Stage 1 -- compile PX4 SITL.
# Your (possibly unpushed) PX4 source changes are baked into the binary here;
# only the compiled result is shipped to the final image (no .git, no source).
# ---------------------------------------------------------------------------
FROM ${BASE_IMAGE} AS px4-builder
SHELL ["/bin/bash", "-c"]
ENV DEBIAN_FRONTEND=noninteractive

COPY PX4-Autopilot /opt/PX4-Autopilot
# PX4's own setup script installs the exact SITL toolchain for this fork's version.
RUN apt-get update && apt-get install -y --no-install-recommends sudo && \
    /opt/PX4-Autopilot/Tools/setup/ubuntu.sh --no-nuttx --no-sim-tools && \
    rm -rf /var/lib/apt/lists/*
# Build-only: `make px4_sitl_default` with NO simulator target compiles the
# SITL binary WITHOUT launching it. (Appending a sim target such as `none`,
# `gazebo`, or `jmavsim` would build AND run px4 -> hangs the Docker build.)
# Pegasus launches the resulting binary itself over MAVLink at runtime.
RUN cd /opt/PX4-Autopilot && make px4_sitl_default

# ---------------------------------------------------------------------------
# Stage 2 -- the sim-stack image.
# Everything lands under the SAME absolute path as the host repo so that
# hard-coded /home/usrg/IsaacPX4/... paths in configs/launch/tmux still resolve.
# ---------------------------------------------------------------------------
FROM ${BASE_IMAGE} AS simstack
SHELL ["/bin/bash", "-c"]
ENV DEBIAN_FRONTEND=noninteractive
# ISAACLAB_PATH is inherited from the base image (=/workspace/isaaclab).
ENV ISAACSIM_PATH=${ISAACLAB_PATH}/_isaac_sim
ENV IPX4=/home/usrg/IsaacPX4
WORKDIR ${IPX4}

# Let host-style paths that point at IsaacLab resolve to the base image's copy.
RUN mkdir -p ${IPX4} && ln -sf ${ISAACLAB_PATH} ${IPX4}/IsaacLab

# --- PX4 SITL: ship only the compiled build + ROMFS init scripts -----------
COPY --from=px4-builder /opt/PX4-Autopilot/build/px4_sitl_default ${IPX4}/PX4-Autopilot/build/px4_sitl_default
COPY --from=px4-builder /opt/PX4-Autopilot/ROMFS                  ${IPX4}/PX4-Autopilot/ROMFS

# --- PegasusSimulator: copy fork + install extension into Isaac Sim python --
COPY PegasusSimulator ${IPX4}/PegasusSimulator
# Point Pegasus at the in-container PX4 (no-op if the path already matches).
RUN sed -i "s#^px4_dir:.*#px4_dir: ${IPX4}/PX4-Autopilot#" \
      ${IPX4}/PegasusSimulator/extensions/pegasus.simulator/config/configs.yaml
RUN ${ISAACSIM_PATH}/python.sh -m pip install --no-cache-dir \
      numpy scipy pymavlink pyyaml toml && \
    ${ISAACSIM_PATH}/python.sh -m pip install --no-cache-dir -e \
      ${IPX4}/PegasusSimulator/extensions/pegasus.simulator

# --- gimbal_stabilizer: build in an overlay ROS2 workspace -----------------
COPY ros2_ws/src/gimbal_stabilizer ${IPX4}/ros2_ws/src/gimbal_stabilizer
RUN apt-get update && apt-get install -y --no-install-recommends \
      ros-humble-tf2-ros ros-humble-geometry-msgs ros-humble-sensor-msgs && \
    rm -rf /var/lib/apt/lists/* && \
    source /opt/ros/humble/setup.bash && \
    cd ${IPX4}/ros2_ws && \
    colcon build --packages-select gimbal_stabilizer && \
    echo "source ${IPX4}/ros2_ws/install/setup.bash" >> /root/.bashrc

# --- Dependencies for the `mas` stack (built at runtime from a mounted repo),
#     plus tmux/tmuxp and the QGC/uXRCE runtime+build deps. ros-base omits
#     OpenCV / vision_opencv, and mas builds cv_bridge, image_geometry,
#     px4_msgs, mas_* from source, so it needs their *build* deps.
#     NOTE: pcl_ros / pcl_conversions / rviz2 are intentionally NOT installed --
#     they are blocked by a libbrotli 1.1.0 (deb.sury.org) vs libbrotli-dev 1.0.9
#     conflict in the Isaac Sim base that cascades through libfreetype6-dev. Only
#     `ultralytics_ros` needs them (and it needs torch/ultralytics anyway), so it
#     is the one mas package that won't build here -- skip it or see notes.
#     `python3-pymavlink` is pip-only (installed below), not an apt package.
#     IMPORTANT: no inline `#` comments inside this RUN — the shell would treat
#     them as comments across the `\` continuations and silently drop packages.
RUN apt-get update && apt-get install -y --no-install-recommends \
      libopencv-dev python3-opencv libboost-python-dev libboost-dev libeigen3-dev \
      libgstrtspserver-1.0-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
      gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly \
      python3-scipy python3-yaml python3-numpy python3-transforms3d python3-pip \
      ros-humble-mavros-msgs ros-humble-tf2-eigen ros-humble-tf2-geometry-msgs \
      ros-humble-tf-transformations ros-humble-image-transport ros-humble-message-filters \
      ros-humble-geographic-msgs ros-humble-vision-msgs ros-humble-python-cmake-module \
      tmux tmuxp \
      libssl-dev libasio-dev libtinyxml2-dev \
      libfuse2 libgl1 libpulse0 libxcb-xinerama0 libxkbcommon-x11-0 && \
    rm -rf /var/lib/apt/lists/* && \
    pip3 install --no-cache-dir pymavlink

# --- Micro-XRCE-DDS Agent (built from source; exposed as micro-xrce-dds-agent).
#     The superbuild has no top-level `install` target and builds Fast-CDR /
#     microCDR / client into build/temp_install, so: `cmake --install` the agent,
#     then copy the thirdparty .so's it links against into /usr/local/lib.
RUN git clone -b v2.4.3 --depth 1 https://github.com/eProsima/Micro-XRCE-DDS-Agent.git /tmp/uxrce && \
    cmake -S /tmp/uxrce -B /tmp/uxrce/build -DCMAKE_BUILD_TYPE=Release -DUAGENT_BUILD_EXECUTABLE=ON -DCMAKE_INSTALL_PREFIX=/usr/local && \
    cmake --build /tmp/uxrce/build -j"$(nproc)" && \
    cmake --install /tmp/uxrce/build && \
    find /tmp/uxrce/build/temp_install -name '*.so*' -exec cp -a {} /usr/local/lib/ ';' && \
    ldconfig && \
    ln -sf /usr/local/bin/MicroXRCEAgent /usr/local/bin/micro-xrce-dds-agent && \
    rm -rf /tmp/uxrce

# --- Host-workflow env: the tmux configs source env/*.sh and use ${HOME}-
#     relative paths. Copy env/, point the Isaac Sim ROS2-bridge LD path at the
#     container's copy, provide an ISAACSIM_PYTHON command, and symlink the
#     ${HOME}(=/root)-relative paths to their real container locations.
COPY env ${IPX4}/env
RUN sed -i \
      -e 's#/home/usrg/isaacsim/exts/isaacsim.ros2.bridge/humble/lib#/isaac-sim/exts/isaacsim.ros2.bridge/humble/lib#g' \
      -e 's#/home/usrg/.local/share/ov/pkg/isaac-sim-4.2.0/exts/omni.isaac.ros2_bridge/humble/lib#/isaac-sim/exts/isaacsim.ros2.bridge/humble/lib#g' \
      ${IPX4}/env/*.sh && \
    printf '%s\n' '#!/bin/bash' 'exec /isaac-sim/python.sh "$@"' > /usr/local/bin/ISAACSIM_PYTHON && \
    chmod +x /usr/local/bin/ISAACSIM_PYTHON && \
    ln -sfn ${IPX4} /root/IsaacPX4 && \
    mkdir -p /root/ros2_humble && ln -sfn /opt/ros/humble /root/ros2_humble/install

# --- QGroundControl (FUSE-less launch via APPIMAGE_EXTRACT_AND_RUN) ---------
COPY QGroundControl.AppImage ${IPX4}/QGroundControl.AppImage
RUN chmod +x ${IPX4}/QGroundControl.AppImage
ENV APPIMAGE_EXTRACT_AND_RUN=1

# --- Sim worlds (USD) + tmux launch configs --------------------------------
COPY world ${IPX4}/world
COPY tmux  ${IPX4}/tmux

# --- YOLO inference runtime for mas `ultralytics_ros` (2D tracker_node.py) ---
#     System python3 (ROS2) gets torch + ultralytics; the drone model weights
#     (.pt/.onnx/.engine) arrive via the mounted mas repo, so they are NOT baked.
#     torch cu118 matches Isaac's bundled build and the host driver (535/CUDA 12.2).
#     The 3D tracker_with_cloud_node (PCL/rviz2) is intentionally not built.
#     NOTE: pins numpy==1.23.4 / opencv-python==4.7 into /usr/local (shadows the
#     apt versions ROS uses — fine for Humble). ultralytics pinned for repro.
ENV YOLO_CONFIG_DIR=/root/.config/Ultralytics
RUN pip3 install --no-cache-dir torch==2.5.1 torchvision==0.20.1 \
      --index-url https://download.pytorch.org/whl/cu118 && \
    pip3 install --no-cache-dir \
      numpy==1.23.4 lap==0.4.0 onnx==1.14.0 urllib3==1.26.18 \
      opencv-python==4.7.0.72 ultralytics==8.4.93 && \
    mkdir -p ${YOLO_CONFIG_DIR}

# --- Ceres Solver 2.2.0 (matches the host's source build; mas_multiview needs it) --
#     Ubuntu 22.04 apt only ships 2.0.0, so build 2.2.0 from source with the same
#     components as the host (EigenSparse;SuiteSparse;LAPACK;SchurSpecializations via
#     glog/gflags + SuiteSparse + LAPACK). The host also enabled the CUDA dense-solver
#     backend; omitted here — it needs the full CUDA toolkit and is not an API change.
RUN apt-get update && apt-get install -y --no-install-recommends \
      libgoogle-glog-dev libgflags-dev libsuitesparse-dev liblapack-dev libblas-dev && \
    rm -rf /var/lib/apt/lists/* && \
    git clone --depth 1 -b 2.2.0 https://github.com/ceres-solver/ceres-solver.git /tmp/ceres && \
    cmake -S /tmp/ceres -B /tmp/ceres/build -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_TESTING=OFF -DBUILD_EXAMPLES=OFF -DBUILD_BENCHMARKS=OFF -DUSE_CUDA=OFF && \
    cmake --build /tmp/ceres/build -j"$(nproc)" --target install && \
    ldconfig && \
    rm -rf /tmp/ceres

CMD ["bash"]
