#!/bin/bash -x

# Copy a managed image between subscriptions (and regions)
# To use this script you must first have a source managed image and a storage account in the subscirpiont and region you want to copy to.
# Parameters
# _______________________________________________________________

# Source Paramenters
sourceSubscriptionID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
sourceSnapshotName="you-snapshot-name"
resourceGroupName="your-source-resource-group"

# Target Parameters
targetStorageAccountRg="your-target-resource-group"
targetSourceSubscriptionID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
targetStorageAccountName="your-target-storage-account-name"
imageStorageContainerName="images"
imageName="copyimage"
targetLocation="eastus2"
# ________________________________________________________________

# Select the subscription w/ the source snapshot and get the snapshot ID
az account set --subscription $sourceSubscriptionID
snapshotId=$(az snapshot show -g $resourceGroupName -n $sourceSnapshotName --query "id" -o tsv )
 
# Generate a time-boxed SAS token to access the snapshot for copying
snapshotSasUrl=$(az snapshot grant-access -g $resourceGroupName -n $sourceSnapshotName --duration-in-seconds 3600 --query properties.output.accessSAS)
# Trim leading and trailing quotes
snapshotSasUrl=${snapshotSasUrl%\"}
snapshotSasUrl=${snapshotSasUrl#\"}

# Switch to the target subscription
az account set --subscription $targetSourceSubscriptionID
 
# Setup the target storage account in the target region. The account must alread exist.
# This will be used to land the snapshot copy
targetStorageAccountKey=$(az storage account keys list -g $targetStorageAccountRg --account-name $targetStorageAccountName --query "[:1].value" -o tsv)

# Generate a time-boxed token to access the target storage account.
end=`date -d "420 minutes" '+%Y-%m-%dT%H:%MZ'`
storageSasToken=$(az storage account generate-sas --expiry $end --permissions aclrpuw --resource-types sco --services b --https-only --account-name $targetStorageAccountName --account-key $targetStorageAccountKey -o tsv)

# Create a container in the account to hold the VHD
az storage container create -n $imageStorageContainerName --account-name $targetStorageAccountName --sas-token $storageSasToken
 
# Copy the snapshot to the target storage account
imageBlobName="$imageName-osdisk.vhd"
copyId=$(az storage blob copy start --source-uri $snapshotSasUrl --destination-blob $imageBlobName --destination-container $imageStorageContainerName --sas-token $storageSasToken --account-name $targetStorageAccountName)
 
# Watch the status of the copy job and wait until it is complete
copyStatus=$(az storage blob show --container-name $imageStorageContainerName -n $imageBlobName --account-name $targetStorageAccountName --sas-token $storageSasToken --query "properties.copy.status") 
while [ "$copyStatus" != "success" ]
do
 copyStatus=$(az storage blob show --container-name $imageStorageContainerName -n $imageBlobName --account-name $targetStorageAccountName --sas-token $storageSasToken --query "properties.copy.status")
 # trim the leading and trailing quotes
 copyStatus=${copyStatus%\"}
 copyStatus=${copyStatus#\"}
 echo $copyStatus
done

# Get the URI to the blob we just created.
blobEndpoint=$(az storage account show -g $targetStorageAccountRg -n $targetStorageAccountName --query "primaryEndpoints.blob" -o tsv)
osDiskVhdUri="$blobEndpoint$imageStorageContainerName/$imageBlobName"
 
# Create a snapshot in the target region using the VHD in the storage account
sourceSnapshotName="$imageName-$targetLocation-snap"
az snapshot create -g $targetStorageAccountRg -n $sourceSnapshotName -l $targetLocation --source $osDiskVhdUri
snapshotId=$(az snapshot show -g $targetStorageAccountRg -n $sourceSnapshotName --query "id" -o tsv )

# Finally, create a new managed image from the snapshot
az image create -g $targetStorageAccountRg -n $imageName -l $targetLocation --os-type Windows --source $snapshotId

#TODO
#Clean up storage account, snapshots, etc.