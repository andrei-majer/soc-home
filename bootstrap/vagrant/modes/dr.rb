# bootstrap/vagrant/modes/dr.rb
# DR mode: bridged adapters on 192.168.1.x. Drop-in replacement for broken .15.
# Optional second bridged adapter for .20 SPAN/IDS ingestion.

module SocLabMode
  module_function

  def apply_nics(vb, spec)
    bridged_iface = ENV.fetch('SOC_BRIDGED_NIC', nil)
    unless bridged_iface
      abort "SOC_BRIDGED_NIC env var not set - run via deploy.ps1 (which detects and caches the NIC)"
    end

    # Adapter 1: NAT - outbound during install (apt, etc.)
    vb.customize ['modifyvm', :id, '--nic1', 'nat']

    # Adapter 2: bridged - VM's LAN identity on 192.168.1.x (eth1 inside guest)
    vb.customize ['modifyvm', :id, '--nic2', 'bridged']
    vb.customize ['modifyvm', :id, '--bridgeadapter2', bridged_iface]
    vb.customize ['modifyvm', :id, '--macaddress2', 'auto']

    # Adapter 3: optional second bridged + promiscuous "Allow All" for Suricata SPAN
    if spec['monitoring_nic']
      vb.customize ['modifyvm', :id, '--nic3', 'bridged']
      vb.customize ['modifyvm', :id, '--bridgeadapter3', bridged_iface]
      vb.customize ['modifyvm', :id, '--nicpromisc3', 'allow-all']
      vb.customize ['modifyvm', :id, '--macaddress3', 'auto']
    end
  end
end
