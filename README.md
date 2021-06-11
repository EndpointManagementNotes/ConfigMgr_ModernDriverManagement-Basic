# ConfigMgr_ModernDriverManagement-Basic

Kind of simplfied version of the excellent https://github.com/MSEndpointMgr/ModernDriverManagement
 
Removed all functions and compiled into one script without functions in the hope it reads better and can help with future troubleshooting
There isn't much error checking, but the whole script is designed within a Try, Catch and Finally to assist with error handling

The script works with the following workflow

1. Sets up variables and environmental components
2. Gets computer details (Manufacturer, Model etc.)
3. Connects to ConfigMgr to retreive all packages which start with a specific string
4. Matches driver package to computer details
5. Downloads the driver package
6. Unzipps and then installs the drivers

I have sectioned out the script in that above format. This code has no error handling and no logging, and just flows from top to bottom. It just serves the purpose of putting everything together into one complete script in it's most basic form.

What is also required are some variables that need to be established before the script is run. This will be accomplished by setting up a dynamic variable step before the running of the script.

DRV_CMServer
The server hosting Admin Service API (usually the Primary Site server)


DRV_DriverFilter
The start of the Driver package to allow filtering to separate normal packages with packages to be used for driver installs (usually "Drivers - ") 


DRV_UserName
A user account that has read access to the Admin Service ("DomainName\UserName")


DRV_UserPassword
User password for the DRV_UserName account being used


DRV_DriverPackageZipFileName
The name of the zip files that is within the package source




Below is how to set these up in the task sequence

![image](https://user-images.githubusercontent.com/85554673/121677975-7cb09680-caae-11eb-9c20-f794c3b57b99.png)
