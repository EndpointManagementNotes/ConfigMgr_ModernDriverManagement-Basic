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
7. 
