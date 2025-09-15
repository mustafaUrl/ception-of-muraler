# Bonus Part - GitLab Setup

This directory contains the necessary files to set up a GitLab instance in a k3d cluster running inside a Vagrant VM.

## Instructions

1.  **Start the Vagrant VM:**

    From this (`bonus_2`) directory, run:
    ```
    vagrant up
    ```
    This will create and provision a new Ubuntu VM with Docker, k3d, kubectl, and Helm installed.

2.  **SSH into the VM:**

    ```
    vagrant ssh
    ```

3.  **Run the Setup Script:**

    Once inside the VM, navigate to the synced `scripts` folder and execute the setup script:
    ```
    cd /vagrant/scripts
    bash setup.sh
    ```
    This script will:
    - Create a k3d cluster named `gitlab-cluster`.
    - Create a `gitlab` namespace.
    - Install GitLab using the official Helm chart with the configurations from `../confs/values.yaml`.

    The installation will take a significant amount of time (10-20 minutes or more depending on your machine).

4.  **Access GitLab:**

    Once the installation is complete, you need to get the initial root password:
    ```
    kubectl get secret -n gitlab gitlab-gitlab-initial-root-password -o jsonpath='{.data.password}' | base64 --decode ; echo
    ```
    You can now access GitLab in your browser at `http://gitlab.192.168.56.110.nip.io`.

    Login with the username `root` and the password you just retrieved.

## Integrating with Part 3

This bonus part sets up GitLab in a new, separate k3d cluster (`gitlab-cluster`) to avoid conflicts and resource issues with the existing Part 3 setup (`mycluster`).

To fulfill the requirement that "Everything you did in Part 3 must work with your local Gitlab", you would typically:

1.  Create a new project in your local GitLab instance.
2.  Push the `Inception-of-Things` repository code to this new project.
3.  Update the ArgoCD application (`my-app` from Part 3) to point to the new repository URL in your local GitLab instead of the public GitHub URL.

This can be done via the ArgoCD UI or by using the `argocd app set` command.
