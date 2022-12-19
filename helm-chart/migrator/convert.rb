require 'yaml'
old_yaml = YAML.load_file("old.yaml")

latest_version = "0.5.16"
new_yaml = {}

if old_yaml["harbor"] && old_yaml["harbor"]["enabled"]
  puts "migrate manually"
  exit
end

if old_yaml["prometheus"] && old_yaml["prometheus"]["enabled"]
  puts "migrate manually"
  exit
end

if old_yaml["kube-prometheus-stack"]
  puts "migrate manually"
  exit
end

if agent = old_yaml["agent"]
  x = agent.slice(*%w(
    accessToken
    apiServer
    containerLogFormat
    containerLogPath
    env
    imageVersion
    ingressEndpoint
    localStorageClassName
    logLevel
    providerType
    sentryDsn
    dcgm
    clusterName
    customImageSource
    )).compact

  if x["imageVersion"] != latest_version
    puts "Will update image version from #{x["imageVersion"]} to #{latest_version}"
    x["imageVersion"] = latest_version
  end

  unless x["clusterName"]
    puts "Input clusterName"
    cluster_name = gets
    x["clusterName"] = cluster_name.strip
  end

  new_yaml["agent"] = x
end

if ndp = old_yaml["nvidiaDevicePlugin"]
  x = ndp.slice("deviceListStrategy").compact
  new_yaml["nvidia-device-plugin"] = x unless x.empty?
end

if lpp = old_yaml["localPathProvisioner"]
  x = lpp.slice("hostPath", "provisionerName").compact
  new_yaml["localPathProvisioner"] = x unless x.empty?
end

if old_yaml["metricsExporters"] && old_yaml["metricsExporters"]["dcgmExporter"]
  dcgm = old_yaml["metricsExporters"]["dcgmExporter"]
  x = dcgm.slice("useDeviceName", "podResourcePath").compact
  unless x.empty?
    new_yaml["metricsExporters"] = {
      "dcgmExporter" => x
    }
  end
end

if old_yaml["tolerations"]
  new_yaml["tolerations"] = old_yaml["tolerations"]
end

File.write("new.yaml", YAML.dump(new_yaml.compact))
