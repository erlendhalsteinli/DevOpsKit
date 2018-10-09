Set-StrictMode -Version Latest 
class ServiceFabric : SVTBase
{       
    hidden [PSObject] $ResourceObject;
	hidden [string] $ClusterTagValue;
	hidden [PSObject] $ApplicationList;
	hidden [string] $DefaultTagName = "clusterName"
    hidden [string] $CertStoreLocation = "CurrentUser"
    hidden [string] $CertStoreName = "My"
    ServiceFabric([string] $subscriptionId, [SVTResource] $svtResource): 
        Base($subscriptionId, $svtResource) 
    { 
        $this.GetResourceObject();
		
    }

	hidden [PSObject] GetResourceObject()
    {
        if (-not $this.ResourceObject) 
		{
            $this.ResourceObject =  Get-AzureRmResource -ResourceGroupName $this.ResourceContext.ResourceGroupName -ResourceType $this.ResourceContext.ResourceType -Name $this.ResourceContext.ResourceName -ApiVersion 2016-03-01        

			$this.ResourceObject.Tags.GetEnumerator() | Where-Object { $_.Key -eq $this.DefaultTagName } | ForEach-Object {$this.ClusterTagValue = $_.Value }
			
			## Commented below two lines of code. This will be covered once Service Fabric module gets available as part of AzureRM modules set.
			#$this.CheckClusterAccess();
			#$this.ApplicationList = Get-ServiceFabricApplication 
            
			if(-not $this.ResourceObject)
            {
                throw ([SuppressedException]::new(("Resource '{0}' not found under Resource Group '{1}'" -f ($this.ResourceContext.ResourceName), ($this.ResourceContext.ResourceGroupName)), [SuppressedExceptionType]::InvalidOperation))
            }
        }
        return $this.ResourceObject;
    }

	[ControlItem[]] ApplyServiceFilters([ControlItem[]] $controls)
	{
		$result = @();
		#Check VM type
		$VMType = $this.ResourceObject.Properties.vmImage
        if($VMType -eq "Linux")
        {
			$result += $controls | Where-Object { $_.Tags -contains "Linux" };
		}
		else
		{
			$result += $controls | Where-Object { $_.Tags -contains "Windows" };;
		}
		return $result;
	}

	hidden [ControlResult] CheckSecurityMode([ControlResult] $controlResult)
	{
		$isCertificateEnabled = [Helpers]::CheckMember($this.ResourceObject.Properties,"certificate" ) 
		
		#Validate if primary certificate is enabled on cluster. Presence of certificate property value indicates, security mode is turned on.
		if($isCertificateEnabled)
        {			
			$controlResult.AddMessage([VerificationResult]::Passed,"Service Fabric cluster is secured with certificate", $this.ResourceObject.Properties.certificate);
        }
        else
        {			
			$controlResult.AddMessage([VerificationResult]::Failed,"Service Fabric cluster is not secured with certificate");
        }
		return $controlResult;    
	}

	hidden [ControlResult] CheckClusterCertificateSSL([ControlResult] $controlResult)
	{
		$managementEndpointUri = $this.ResourceObject.Properties.managementEndpoint
		$managementEndpointUriScheme = ([System.Uri]$managementEndpointUri).Scheme               

		#Validate if cluster management endpoint url is SSL enabled
		if($managementEndpointUriScheme -eq "https")
		{   
			#Hit web request to management endpoint uri and validate certificate trust level             
			$request = [System.Net.HttpWebRequest]::Create($managementEndpointUri) 
			try
			{
				$request.GetResponse().Dispose()
				$controlResult.AddMessage([VerificationResult]::Passed,"Service Fabric cluster is protected with CA signed certificate");                    
			}
			catch [System.Net.WebException]
			{
				#Trust failure indicates self-signed certificate or domain mismatch certificate present on endpoint
				if ($_.Exception.Status -eq [System.Net.WebExceptionStatus]::TrustFailure)
				{                        
					$controlResult.AddMessage([VerificationResult]::Verify,"Validate if self-signed certificate is not used for cluster management endpoint protection",$this.ResourceObject.Properties.managementEndpoint);
					$controlResult.SetStateData("Management endpoint", $this.ResourceObject.Properties.managementEndpoint);
				}
				elseif($_.Exception.Message.Contains('403'))
				{
					$controlResult.AddMessage([VerificationResult]::Passed,"Service Fabric cluster is protected with CA signed certificate");
				}
				else
				{					
				    $controlResult.AddMessage([VerificationResult]::Manual,"Unable to fetch certificate details of the cluster. Please verify manually that Service Fabric cluster is protected with CA signed certificate.");
					$controlResult.AddMessage($_.Exception.Message);
					#throw $_
				}
			}
		}
		else
		{
			$controlResult.AddMessage([VerificationResult]::Failed,"Service Fabric cluster is not protected by SSL")
		}
		return $controlResult;    
	}

	hidden [ControlResult] CheckAADClientAuthentication([ControlResult] $controlResult)
	{
		$isAADEnabled = [Helpers]::CheckMember($this.ResourceObject.Properties,"azureActiveDirectory")
		
		#Presence of 'AzureActiveDirectory' indicates, AAD authentication is enabled for client authentication
		if($isAADEnabled)
        {			
			$controlResult.AddMessage([VerificationResult]::Passed,"AAD is enabled for client authentication",$this.ResourceObject.Properties.azureActiveDirectory )
        }
        else
        {			
			$controlResult.AddMessage([VerificationResult]::Failed,"AAD is not enabled for client authentication")
        }

		return $controlResult
	}

	hidden [ControlResult] CheckClusterProtectionLevel([ControlResult] $controlResult)
	{
		$fabricSecuritySettings = $this.ResourceObject.Properties.fabricSettings | Where-Object {$_.Name -eq "Security"}

		#Absence of security settings indicates, secure mode is not enabled on cluster.
		if($null -ne $fabricSecuritySettings)
		{
			$clusterProtectionLevel = $fabricSecuritySettings.parameters | Where-Object { $_.name -eq "ClusterProtectionLevel"}
			if($clusterProtectionLevel.value -eq "EncryptAndSign")
			{
			  $controlResult.AddMessage([VerificationResult]::Passed,"Cluster security is ON with 'EncryptAndSign' protection level",$clusterProtectionLevel);
			}
			else 
			{
			  $controlResult.AddMessage([VerificationResult]::Failed,"Cluster security is not set with 'EncryptAndSign' protection level. Current protection level is :", $clusterProtectionLevel);
				$controlResult.SetStateData("Cluster protection level", $clusterProtectionLevel);
			}
		}
		else
		{
		  $controlResult.AddMessage([VerificationResult]::Failed,"Cluster security is OFF");
		}

		return $controlResult
	}

	hidden [ControlResult[]] CheckNSGConfigurations([ControlResult] $controlResult)
	{
		$isVerify = $true;
		$nsgEnabledVNet = @{};
		$nsgDisabledVNet = @{};

		$virtualNetworkResources = $this.GetLinkedResources("Microsoft.Network/virtualNetworks") 
        #Iterate through all cluster linked VNet resources      
		$virtualNetworkResources |ForEach-Object{            
			$virtualNetwork=Get-AzureRmVirtualNetwork -ResourceGroupName $_.ResourceGroupName -Name $_.Name 
			$subnetConfig = Get-AzureRmVirtualNetworkSubnetConfig -VirtualNetwork $virtualNetwork
			#Iterate through Subnet and validate if NSG is configured or not
			$subnetConfig | ForEach-Object{
				$subnetName =$_.Name
				$isCompliant =  ($null -ne $_.NetworkSecurityGroup)		
				#If NSG is enabled on Subnet display all security rules applied 
				if($isCompliant)
				{
					$nsgResource = Get-AzureRmResource -ResourceId $_.NetworkSecurityGroup.Id
					$nsgResourceDetails = Get-AzureRmNetworkSecurityGroup -ResourceGroupName $nsgResource.ResourceGroupName -Name $nsgResource.Name                
					
					$nsgEnabledVNet.Add($subnetName, $nsgResourceDetails)
				}
				#If NSG is not enabled on Subnet, fail the TCP with Subnet details
				else
				{
					$nsgDisabledVNet.Add($subnetName, $_)
					$isVerify = $false
				} 
			}                
		}

		if($nsgEnabledVNet.Keys.Count -gt 0)
		{
			$nsgEnabledVNet.Keys  | Foreach-Object {
				$controlResult.AddMessage("Validate NSG security rules applied on subnet '$_'",$nsgEnabledVNet[$_]);
			}
		}

		if($nsgDisabledVNet.Keys.Count -gt 0)
		{
			$nsgDisabledVNet.Keys  | Foreach-Object {
				$controlResult.AddMessage("NSG is not configured on subnet '$_'",$nsgDisabledVNet[$_]);
			}
		}

		if($isVerify)
		{
			$controlResult.VerificationResult = [VerificationResult]::Verify;
		}
		else
		{
			$controlResult.VerificationResult = [VerificationResult]::Failed;
		}

		$NSGState = New-Object -TypeName PSObject 
		$NSGState | Add-Member -NotePropertyName NSGConfiguredSubnet -NotePropertyValue $nsgEnabledVNet
		$NSGState | Add-Member -NotePropertyName NSGNotConfiguredSubnet -NotePropertyValue $nsgDisabledVNet

		$controlResult.SetStateData("NSG security rules applied on subnet", $NSGState);

		return $controlResult        
	}

	hidden [ControlResult[]] CheckVmssDiagnostics([ControlResult] $controlResult)
	{
		$isPassed = $true;
		$diagnosticsEnabledScaleSet = @{};
		$diagnosticsDisabledScaleSet = @{};
		$vmssResources = $this.GetLinkedResources("Microsoft.Compute/virtualMachineScaleSets")
		#Iterate through cluster linked vmss resources             
		$vmssResources | ForEach-Object{
			$VMScaleSetName = $_.Name	
			$nodeTypeResource = Get-AzureRmVmss -ResourceGroupName  $_.ResourceGroupName -VMScaleSetName  $VMScaleSetName

			# Fetch diagnostics settings based on OS 
			if($this.ResourceObject.Properties.vmImage -eq "Linux")
			{
				$diagnosticsSettings = $nodeTypeResource.VirtualMachineProfile.ExtensionProfile.Extensions  | ? { $_.Type -eq "LinuxDiagnostic" -and $_.Publisher -eq "Microsoft.OSTCExtensions" }				
			}
			else
			{
       			$diagnosticsSettings = $nodeTypeResource.VirtualMachineProfile.ExtensionProfile.Extensions  | ? { $_.Type -eq "IaaSDiagnostics" -and $_.Publisher -eq "Microsoft.Azure.Diagnostics" }
			}
			#Validate if diagnostics is enabled on vmss 
			if($null -ne $diagnosticsSettings )
			{
				$diagnosticsEnabledScaleSet.Add($VMScaleSetName, $diagnosticsSettings)		
			}
			else
			{
				$isPassed = $false;
				$diagnosticsDisabledScaleSet.Add($VMScaleSetName, $diagnosticsSettings)		
			} 
		}

		if($diagnosticsEnabledScaleSet.Keys.Count -gt 0)
		{
			$diagnosticsEnabledScaleSet.Keys  | Foreach-Object {
				$controlResult.AddMessage("Diagnostics is enabled on Vmss '$_'",$diagnosticsEnabledScaleSet[$_]);
			}
		}

		if($diagnosticsDisabledScaleSet.Keys.Count -gt 0)
		{
			$diagnosticsDisabledScaleSet.Keys  | Foreach-Object {
				$controlResult.AddMessage("Diagnostics is disabled on Vmss '$_'",$diagnosticsDisabledScaleSet[$_]);
			}
		}

		if($isPassed)
		{
			$controlResult.VerificationResult = [VerificationResult]::Passed;
		}
		else
		{
			$controlResult.VerificationResult = [VerificationResult]::Failed;
			$controlResult.SetStateData("Diagnostics is disabled on Vmss", $diagnosticsDisabledScaleSet);
		}
		return $controlResult        
	}
	hidden [ControlResult[]] CheckReverseProxyPort([ControlResult] $controlResult)
	{
		# add attestation details
		$isPassed = $true;
		$reverseProxyEnabledNode = @{};
		$reverseProxyDisabledNode = @();
		$reverseProxyExposedNode = @{};
		$nodeTypes= $this.ResourceObject.Properties.nodeTypes
		#Iterate through each node           
		$nodeTypes | ForEach-Object{

			if([Helpers]::CheckMember($_,"reverseProxyEndpointPort"))
			{
				$reverseProxyEnabledNode.Add($_.name, $_.reverseProxyEndpointPort)
			}else{
				$reverseProxyDisabledNode += $_.name
			}
		}
		# if reverse proxy is not enabled in any node, pass TCP
		if(($reverseProxyEnabledNode | Measure-Object).Count -gt 0)
		{
			$loadBalancerBackendPorts = @()
			$loadBalancerResources = $this.GetLinkedResources("Microsoft.Network/loadBalancers")
			#Collect all open ports on load balancer  
			$loadBalancerResources | ForEach-Object{
				$loadBalancerResource = Get-AzureRmLoadBalancer -Name $_.Name -ResourceGroupName $_.ResourceGroupName
				$loadBalancingRules = @($loadBalancerResource.FrontendIpConfigurations | ? { $null -ne $_.PublicIpAddress } | ForEach-Object { $_.LoadBalancingRules })
			
				$loadBalancingRules | ForEach-Object {
					$loadBalancingRuleId = $_.Id;
					$loadBalancingRule = $loadBalancerResource.LoadBalancingRules | ? { $_.Id -eq  $loadBalancingRuleId } | Select-Object -First 1
					$loadBalancerBackendPorts += $loadBalancingRule.BackendPort;
				};   
			}
			#If no ports open, Pass the TCP
			if($loadBalancerBackendPorts.Count -eq 0)
			{
				$controlResult.AddMessage("No ports enabled in load balancer.")  
				$controlResultList += $controlResult      
			}
			#If Ports are open for public in load balancer, check if any reverse proxy port is exposed
			else
			{
				$reverseProxyEnabledNode.Keys  | Foreach-Object {
					if($loadBalancerBackendPorts.Contains($reverseProxyEnabledNode[$_]))
					{
						$isPassed = $false;
						$controlResult.AddMessage("Reverse proxy port is publicly exposed for node '$_':",$reverseProxyEnabledNode[$_]);
						$reverseProxyExposedNode.Add($_, $reverseProxyEnabledNode[$_])
					}
					
				}
			}
		}else{
			$controlResult.AddMessage("Reverse proxy service is not enabled in cluster.") 
		}
		if($isPassed)
		{
			$controlResult.VerificationResult = [VerificationResult]::Passed;
		}
		else
		{
			$controlResult.VerificationResult = [VerificationResult]::Failed;
			$controlResult.SetStateData("Diagnostics is disabled on Vmss", $reverseProxyExposedNode);
		}
		return $controlResult
	}

	hidden [ControlResult] CheckClusterUpgradeMode([ControlResult] $controlResult)
	{
		if([Helpers]::CheckMember($this.ResourceObject.Properties,"upgradeMode") -and $this.ResourceObject.Properties.upgradeMode -eq "Automatic")
        {			
			$controlResult.AddMessage([VerificationResult]::Passed,"Upgrade mode for cluster is set to automatic." )
        }
        else
        {			
			$controlResult.AddMessage([VerificationResult]::Failed,"Upgrade mode for cluster is set to manual.")
        }

		return $controlResult
	}

	hidden [ControlResult[]] CheckStatefulServiceReplicaSetSize([ControlResult] $controlResult)
	{
		$isPassed = $true;
		$complianteServices = @{};
		$nonComplianteServices = @{};
		#Iterate through the applications present in cluster     
		if($this.ApplicationList)
		{
			$this.ApplicationList | ForEach-Object{
				$serviceFabricApplication = $_

				Get-ServiceFabricService -ApplicationName $serviceFabricApplication.ApplicationName  | ForEach-Object{                
					$serviceName = $_.ServiceName 
					$serviceDescription = Get-ServiceFabricServiceDescription -ServiceName $_.ServiceName 
					#Filter application with Stateful service type
					if($serviceDescription.ServiceKind -eq "Stateful")
					{
						#Validate minimum replica and target replica size for each service 					
						$isCompliant = !($serviceDescription.MinReplicaSetSize -lt 3 -or $serviceDescription.TargetReplicaSetSize -lt 3)

						if($isCompliant)
						{
							$complianteServices.Add($serviceName, $serviceDescription)
						} 
						else
						{ 
							$isPassed = $False
							$nonComplianteServices.Add($serviceName, $serviceDescription)
						}
					}                
				}
			}

			if($complianteServices.Keys.Count -gt 0)
			{
				$controlResult.AddMessage("Replica set size for below services are complaint");
				$complianteServices.Keys  | Foreach-Object {
					$controlResult.AddMessage("Replica set size details for service '$_'");
				}
			}

			if($nonComplianteServices.Keys.Count -gt 0)
			{
				$controlResult.AddMessage("Replica set size for below services are non-complaint");
				$nonComplianteServices.Keys  | Foreach-Object {
					$controlResult.AddMessage("Replica set size details for service '$_'",$nonComplianteServices[$_]);
				}
			}

			if($isPassed)
			{
				$controlResult.VerificationResult = [VerificationResult]::Passed;
			}
			else
			{
				$controlResult.VerificationResult = [VerificationResult]::Failed;
				$controlResult.SetStateData("Replica set size are non-complaint for", $nonComplianteServices);
			}
		}
		else
		{
			$controlResult.AddMessage([VerificationResult]::Passed,"No stateful service found.")
		}
		return $controlResult;
	}

	[void] CheckClusterAccess()
	{	
		#Function to validate authentication and connect with Service Fabric cluster     
        $sfCluster = $null       
        $uri = ([System.Uri]$this.ResourceObject.Properties.managementEndpoint).Host                
        $primaryNodeType = $this.ResourceObject.Properties.nodeTypes | Where-Object { $_.isPrimary -eq $true }
                
        $ClusterConnectionUri = $uri +":"+ $primaryNodeType.clientConnectionEndpointPort
        $this.PublishCustomMessage("Connecting with Service Fabric cluster...")
        $this.PublishCustomMessage("Validating if Service Fabric is secure...")
        
        $isClusterSecure =  [Helpers]::CheckMember($this.ResourceObject.Properties,"certificate" )               
                
        if($isClusterSecure)
        {
			$serviceFabricCertificate = $this.ResourceObject.Properties.certificate              
            $this.PublishCustomMessage("Service Fabric is secure")
            $CertThumbprint= $this.ResourceObject.Properties.certificate.thumbprint
            $serviceFabricAAD =$this.ResourceObject.Properties.azureActiveDirectory
            if($null -ne $serviceFabricAAD)
            {
                try
                {
                    $this.PublishCustomMessage("Connecting Service Fabric using AAD...")
                    $sfCluster = Connect-ServiceFabricCluster -ConnectionEndpoint $ClusterConnectionUri -AzureActiveDirectory -ServerCertThumbprint $CertThumbprint #-SecurityToken "
                     $this.PublishCustomMessage("Connection using AAD is successful.")
                }
                catch
                {
					throw ([SuppressedException]::new(("You may not have permission to connect with cluster"), [SuppressedExceptionType]::InvalidOperation))
                }
            }              
            else
            {
                $this.PublishCustomMessage("Validating if cluster certificate present on machine...")
                $IsCertPresent = (Get-ChildItem -Path Cert:\$this.CertStoreLocation\$this.CertStoreName | Where-Object {$_.Thumbprint -eq $CertThumbprint }).Count                    
                if($IsCertPresent)
                {
                    $this.PublishCustomMessage("Connecting Service Fabric using certificate")
                    $sfCluster = Connect-serviceFabricCluster -ConnectionEndpoint $ClusterConnectionUri -KeepAliveIntervalInSec 10 -X509Credential -ServerCertThumbprint $CertThumbprint -FindType FindByThumbprint -FindValue $CertThumbprint -StoreLocation $this.CertStoreLocation -StoreName $this.CertStoreName 
                }
                else
                {
					throw ([SuppressedException]::new(("Cannot connect with Service Fabric due to unavailability of cluster certificate in local machine. Validate cluster certificate is present in 'CurrentUser' location."), [SuppressedExceptionType]::InvalidOperation))
                }
            }                    
        }
        else
        {
            $this.PublishCustomMessage("Service Fabric is unsecure");
            $sfCluster = Connect-serviceFabricCluster -ConnectionEndpoint $ClusterConnectionUri
            $this.PublishCustomMessage("Service Fabric connection is successful");
        }
	}

	[PSObject] GetLinkedResources([string] $resourceType)
	{
	    return  Get-AzureRmResource -TagName $this.DefaultTagName -TagValue $this.ClusterTagValue | Where-Object { ($_.ResourceType -EQ $resourceType) -and ($_.ResourceGroupName -eq $this.ResourceContext.ResourceGroupName) }
	}	
}