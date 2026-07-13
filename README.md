# IsaacPX4 — Full Simulation Stack (Docker)

A single Docker image containing the complete multi-agent aerial simulation stack:

- **Isaac Sim 4.5 + Isaac Lab** (GPU/RTX rendering + physics)
- **PegasusSimulator** (aerial-vehicle extension) driving **PX4 SITL** over MAVLink
- **ROS 2 Humble** + `gimbal_stabilizer` overlay
- **`mas`** build deps: OpenCV, Ceres 2.2.0, GStreamer, tf2, mavros-msgs, … (the `mas` source is mounted at runtime)
- **YOLO runtime** (PyTorch cu118 + Ultralytics) for `ultralytics_ros`
- **Micro-XRCE-DDS Agent**, **QGroundControl**, **tmux/tmuxp**

> Replace `swl017/isaacpx4-simstack` below with the actual Docker Hub repository.

---

## 1. Prerequisites (on the host)

| Requirement | Notes |
|---|---|
| NVIDIA GPU | Tested on RTX 3090 (24 GB). |
| NVIDIA driver ≥ 535 | Must support CUDA 11.8 (torch cu118). `nvidia-smi` should work. |
| Docker + Docker Compose v2 | `docker compose version` should print v2.x. |
| `nvidia-container-toolkit` | Provides the `nvidia` runtime used by the container. |
| X11 desktop session | Needed for the Isaac Sim / QGroundControl GUIs. |
| ~40 GB free disk | ~30 GB image + shader cache + logs. |

Quick host check:

```bash
nvidia-smi                       # GPU + driver visible
docker info | grep -i runtimes   # must list "nvidia"
echo $DISPLAY                    # non-empty (e.g. :0 or :1)
```

---

## 2. Get the launch files

`run-simstack.sh`, `docker-compose.yaml`, and the `tmux/` configs live in **this repo**, not in the image. Clone it (or copy those files) onto the host:

```bash
cd ~/
git clone git@github.com:usrg-drone/IsaacPX4.git IsaacPX4
cd IsaacPX4
```

---

## 3. Pull the image from Docker Hub

For a **private** repo, log in first (use a Docker Hub access token as the password):

```bash
docker login -u <your-dockerhub-user>
docker pull swl017/isaacpx4-simstack:latest
```

**Re-tag to the plain name the tooling expects.** `docker-compose.yaml` and `run-simstack.sh` reference `image: isaacpx4-simstack`, so:

```bash
docker tag swl017/isaacpx4-simstack:latest isaacpx4-simstack
```

*(Alternatively, edit the `image:` line in `docker-compose.yaml` to the full repo path.)*

---

## 4. Prepare the runtime mounts

The image is the environment; a few inputs are mounted from the host at run time:

```bash
# The mas ROS2 stack — docker-compose.yaml mounts ~/mas -> /home/usrg/mas.
# Clone it there if you'll build/run the mas perception stack (YOLO, multiview, …).
cd ~/
git clone git@github.com:usrg-drone/mas.git ~/mas

# The Isaac Sim shader/asset cache persists here (auto-created by run-simstack.sh),
# so the slow FIRST launch is a one-time cost:
#   ~/docker/isaac-sim/cache/kit   (shader/PSO cache)
#   ~/docker/isaac-sim/cache/ov    (Omniverse asset cache)
```

> If you don't need the `mas` stack, `~/mas` can be an empty directory — the core
> simulation (Isaac + Pegasus + PX4 + gimbal) does not depend on it.

---

## 5. Run the container

```bash
./run-simstack.sh
```

This wrapper authorizes X11 (`xhost +local:root`), creates the cache dirs, and does
`docker compose run --rm simstack` with GPU (`runtime: nvidia`), host networking, and
X11 already wired up. It drops you into a bash shell **inside** the container at
`/home/usrg/IsaacPX4`.

Other forms:

```bash
./run-simstack.sh --build              # (re)build the image locally instead of pulling
./run-simstack.sh <command...>         # run a one-off command in the container
docker compose run --rm simstack       # the raw equivalent of the default
```

---

## 6. Launch the simulation with tmuxp

From the shell inside the container (you're already at `/home/usrg/IsaacPX4`):

```bash
tmuxp load tmux/isaac_sim_aggressive.tmuxp.yaml
```

This starts a tmux session with three windows:

| Window | What it runs |
|---|---|
| `simulator` | Isaac Sim + PegasusSimulator (auto-spawns the PX4 SITL instances) · `micro-xrce-dds-agent` |
| `ros2` | `gimbal_stabilizer` LOS-rate controller |
| `util` | QGroundControl |

**First launch is slow (a few minutes)** — Isaac Sim compiles RTX shaders on the first
run. CPU sits high and the log pauses after `app ready`; that's normal. The result is
cached to `~/docker/isaac-sim/`, so subsequent launches are fast. You'll know it's up
when PX4 reports `Ready for takeoff!` and the Isaac viewport renders.

Available tmux configs:

| Config | Purpose |
|---|---|
| `isaac_sim_aggressive.tmuxp.yaml` | Full sim + gimbal + QGC (recommended entry point) |
| `isaac_sim.tmuxp.yaml` | Isaac Sim + Pegasus + PX4 |
| `isaac_px4.tmuxp.yaml` | PX4-focused session |
| `isaac_mavros.tmuxp.yaml` | Sim with MAVROS bridge |
| `isaac_sysid.tmuxp.yaml` | System-identification session |
| `train_px4.tmuxp.yaml` | Training session |
| `bridge.yaml` | ROS/DDS bridge helpers |

tmux basics: detach with `Ctrl-b d`, switch windows with `Ctrl-b <n>`, stop everything
with `tmux kill-server`.

---

## 7. Building the `mas` stack (optional)

Inside the container, with `~/mas` mounted:

```bash
source /opt/ros/humble/setup.bash
cd /home/usrg/mas
colcon build            # ceres/opencv/torch deps are baked in; ultralytics_ros builds the 2D node
source install/setup.bash
```

> The 3D `tracker_with_cloud_node` (needs `pcl_ros`/`rviz2`) is not built — those are
> blocked by a `libbrotli` version pin in the Isaac Sim base. The 2D YOLO
> `tracker_node.py` builds and runs on the GPU.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `image 'isaacpx4-simstack' not found` | You skipped the re-tag in step 3. |
| GUI window never appears | `echo $DISPLAY` empty, or run `xhost +local:root` on the host; must be a desktop session. |
| `could not select device driver "nvidia"` | Install/enable `nvidia-container-toolkit`; check `docker info` lists the `nvidia` runtime. |
| Sim seems "stuck" after `app ready` | First-run shader compile — wait a few minutes; it caches to `~/docker/isaac-sim`. |
| `ERROR [simulator_mavlink] poll timeout` at startup | Transient while Isaac finishes loading; stops once physics starts stepping. |
| mas nodes can't find their code | Ensure `~/mas` on the host contains the mas repo (it's bind-mounted, not baked in). |
