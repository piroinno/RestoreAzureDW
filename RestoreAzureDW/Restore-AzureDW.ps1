function Restore-AzureDW {
    [CmdletBinding()]
    param (
        [Parameter (Mandatory= $true)] [string] $SourceServerName,
        [Parameter (Mandatory= $true)] [string] $SourceDbName,
        [Parameter (Mandatory= $true)] [string] $SourceResourceGroup,
        [Parameter (Mandatory= $true)] [string] $SourceSubscription,
        [Parameter (Mandatory= $true)] [string] $TargetResourceGroup,
        [Parameter (Mandatory= $true)] [string] $TargetSubscription,
        [Parameter (Mandatory= $true)] [string] $TargetServerName,
        [Parameter (Mandatory= $true)] [string] $TargetDbName
    )

    begin {
        Write-Verbose "Starting $($MyInvocation.MyCommand.Name)"
        $ErrorActionPreference = "Stop"
        if($TargetDbName -ilike "*prod*" -or $TargetDbName -ilike "*prd*")
        {
            throw New-Object System.Exception ("Cannot restore into a production subscription")
        }

        $_PWD = ConvertTo-SecureString "$((New-Guid).Guid)" -AsPlainText -Force
        $TargetSqlCredential = New-Object System.Management.Automation.PSCredential ("tempAdmin", $_PWD)

        $RestorePointLabel = "$($MyInvocation.MyCommand.Name)-$((New-Guid).Guid)"
        $TempSqlServerName = (New-Guid).Guid
        $TempDatabaseName = (New-Guid).Guid
        $TempResourceGroupName = "$($TempSqlServerName)-PIT-RG"
        if((Get-AzureRmContext).Subscription.Name -ine $SourceSubscription){
            Write-Verbose "Changing security context, now using SourceSubscription: $($SourceSubscription)"
            $null = Set-AzureRmContext $SourceSubscription
        }
        $Database = Get-AzureRmSqlDatabase -ResourceGroupName $SourceResourceGroup -ServerName $SourceServerName -DatabaseName $SourceDbName
        $RestorePhases = 2
        $CleanUpPhases = 5
    }

    process {
        # Create a user defined restore point
        Write-Verbose "Creating restore point with label $($RestorePointLabel)"
        $SourceRestorePoint = New-AzureRmSqlDatabaseRestorePoint -ResourceGroupName $SourceResourceGroup `
            -ServerName $SourceServerName -DatabaseName $SourceDbName `
            -RestorePointLabel $RestorePointLabel

        # If target server is in a different subscription
        # create a new temp server
        if($SourceSubscription -ne $TargetSubscription){
            Write-Verbose "Creating temp resource group: $($TempResourceGroupName)"
            $null = New-AzureRmResourceGroup -Name $TempResourceGroupName -Location (Get-AzureRmResourceGroup -Name $SourceResourceGroup).Location
            Write-Verbose "Creating temp server: $($TempSqlServerName) in resource group $($TempResourceGroupName)"
            $null = New-AzureRmSqlServer -Name $TempSqlServerName -ResourceGroupName $TempResourceGroupName -SqlAdministratorCredentials $TargetSqlCredential `
                -Location (Get-AzureRmResourceGroup -Name $SourceResourceGroup).Location

            $_TempSqlServerName = $TempSqlServerName
            $_TempResourceGroupName = $TempResourceGroupName
        }else{
            $_TempSqlServerName = $TargetServerName
            $_TempResourceGroupName = $TargetResourceGroup
            $RestorePhases = 1
        }

        # Restore from the new restore point
        Write-Verbose "Restoring (phase 1 of $($RestorePhases)) from $($SourceServerName)/$($SourceDbName) to $($_TempSqlServerName)/$($TempDatabaseName)"
        $null = Restore-AzureRmSqlDatabase -FromPointInTimeBackup `
            -PointInTime $SourceRestorePoint.RestorePointCreationDate `
            -ServerName $_TempSqlServerName -TargetDatabaseName $TempDatabaseName `
            -ResourceId $Database.ResourceID -ResourcegroupName $_TempResourceGroupName

        Write-Verbose "Cleanup (phase 1 of $($CleanUpPhases)), removing restore point from $($SourceServerName)/$($SourceDbName)"
        $null = Remove-AzureRmSqlDatabaseRestorePoint -ResourceGroupName $SourceResourceGroup `
            -ServerName $SourceServerName -DatabaseName $SourceDbName -RestorePointCreationDate $SourceRestorePoint.RestorePointCreationDate
        # Move new server to the target subscription
        $CurrentSubscription = (Get-AzureRmContext)
        if($CurrentSubscription.Subscription.Name -ine $TargetSubscription){
            $CleanUpPhases = 6
            Write-Verbose "Moving $($CurrentSubscription.Subscription.Name)/$($TempSqlServerName) to $($TargetSubscription)/$($TempSqlServerName)"
            $TargetSubscriptionId = (Get-AzureRmSubscription -SubscriptionName $TargetSubscription).SubscriptionId
            $SqlServer = Get-AzureRmSqlServer -ResourceGroupName $TempResourceGroupName -ServerName $TempSqlServerName
            $null = Move-AzureRmResource -DestinationResourceGroupName $TargetResourceGroup -DestinationSubscriptionId $TargetSubscriptionId `
                -ResourceId $SqlServer.ResourceId -Force
            Write-Verbose "Cleanup (phase 2 of $($CleanUpPhases)), removing temp resource group $($TempResourceGroupName) from $($SourceSubscription)"
            $null = Remove-AzureRmResourceGroup -ResourceGroupName $TempResourceGroupName -Force

            if((Get-AzureRmContext).Subscription.Name -ine $TargetSubscription){
                Write-Verbose "Changing security context, now using TargetSubscription: $($TargetSubscription)"
                $null = Set-AzureRmContext $TargetSubscription
            }
            # Create a user defined restore point
            $RestorePointLabel = "$($MyInvocation.MyCommand.Name)-$((New-Guid).Guid)"
            $RestorePoint = New-AzureRmSqlDatabaseRestorePoint -ResourceGroupName $TargetResourceGroup `
                -ServerName $TempSqlServerName -DatabaseName $TempDatabaseName `
                -RestorePointLabel $RestorePointLabel

            # Restore from the new restore point
            Write-Verbose "Restoring (phase 2 of $($RestorePhases)) from $($TempSqlServerName)/$($TempDatabaseName) to $($TargetServerName)/$($TempDatabaseName)"
            $Database = $null
            $Database = Get-AzureRmSqlDatabase -ResourceGroupName $TargetResourceGroup -ServerName $TempSqlServerName -DatabaseName $TempDatabaseName
            $null = Restore-AzureRmSqlDatabase -FromPointInTimeBackup `
                -PointInTime $RestorePoint.RestorePointCreationDate `
                -ServerName $TargetServerName -TargetDatabaseName $TempDatabaseName `
                -ResourceId $Database.ResourceID -ResourcegroupName $TargetResourceGroup
        }

        # Cleanup, remove user defiend restore point, remove temp server
        $Database = $null
        $Database = Get-AzureRmSqlDatabase -ResourceGroupName $TargetResourceGroup -ServerName $TargetServerName -DatabaseName $TempDatabaseName -ErrorAction 0
        if($null -ne $Database -and $Database.DatabaseName -eq $TempDatabaseName){
            $Database = $null
            $Database = Get-AzureRmSqlDatabase -ResourceGroupName $TargetResourceGroup -ServerName $TargetServerName -DatabaseName $TargetDbName -ErrorAction 0
            if($null -ne $Database){
                Write-Verbose "Cleanup (phase 3 of $($CleanUpPhases)), renaming $($TargetServerName)/$($TargetDbName) to OLD_$($TargetDbName)"
                $null = Set-AzureRmSqlDatabase -ResourceGroupName $TargetResourceGroup -ServerName $TargetServerName -DatabaseName $TargetDbName -NewName "OLD_$($TargetDbName)"
            }
            Write-Verbose "Cleanup (phase 4 of $($CleanUpPhases)), renaming $($TargetServerName)/$($TempDatabaseName) to $($TargetDbName)"
            $null = Set-AzureRmSqlDatabase -ResourceGroupName $TargetResourceGroup -ServerName $TargetServerName -DatabaseName $TempDatabaseName -NewName $TargetDbName
            $Database = $null
            $Database = Get-AzureRmSqlDatabase -ResourceGroupName $TargetResourceGroup -ServerName $TargetServerName -DatabaseName $TargetDbName -ErrorAction 0
            if($null -ne $Database -and $Database.DatabaseName -eq $TargetDbName){
                $Database = $null
                $Database = Get-AzureRmSqlDatabase -ResourceGroupName $TargetResourceGroup -ServerName $TargetServerName -DatabaseName "OLD_$($TargetDbName)" -ErrorAction 0
                if($null -ne $Database){
                    Write-Verbose "Cleanup (phase 5 of $($CleanUpPhases)), removing $($TargetServerName)/OLD_$($TargetDbName)"
                    $null = Remove-AzureRmSqlDatabase -ResourceGroupName $TargetResourceGroup -ServerName $TargetServerName -DatabaseName "OLD_$($TargetDbName)" -ErrorAction 0
                }
            }
        }
        $SqlServer = $null
        $SqlServer = Get-AzureRmSqlServer -ResourceGroupName $TargetResourceGroup -ServerName $TempSqlServerName -ErrorAction 0
        if($null -ne $SqlServer -and $SqlServer.ServerName -eq $TempSqlServerName){
            Write-Verbose "Cleanup (phase 6 of $($CleanUpPhases)), removing $($TargetResourceGroup)/$($TempSqlServerName)"
            $null = Remove-AzureRmSqlServer -ResourceGroupName $TargetResourceGroup -ServerName $TempSqlServerName -Force -ErrorAction 0
        }
    }

    end {
        Write-Verbose "Ending $($MyInvocation.MyCommand.Name)"
    }
}
