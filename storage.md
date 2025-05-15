# Storage setup

This repo does not setup storage. This is because storage tends to vary significantly. 

To setup storage add two new components:

- `<your storage vendor>-operator`
- `<your storage vendor>-configuration`

Ensure that the operator and configuration work properly on your ACM cluster.
Depending on the situation, you might have to differentiate the configuration by cluster. See the how to use this repo section of the doc to see how to do it.

Ensure that you have the following annotations defined:

- cluster default storage class: `storageclass.kubernetes.io/is-default-class: "true"`
- OpenShift Virtualization default storage class: `storageclass.kubevirt.io/is-default-virt-class: "true"`

This repo requires object storage also. You have to figure out how object storage might be provisioned to the cluster. At the moment the following components require object storage:

- [acm-observability](./components/acm-observability/)