"""Private architecture diagram for the AI Investment Analysis sample.

All resources live in a hub VNet (10.50.0.0/22). Inbound from the internet is
disabled on every PaaS resource. Operator access is via Bastion -> jumpbox ->
SOCKS5 proxy. App-to-PaaS traffic stays on the Microsoft backbone via private
endpoints; the App Service VNet integration subnet reaches AI Foundry through
a service endpoint with a deny-all networkAcl.
"""

from diagrams import Diagram, Cluster, Edge
from diagrams.azure.compute import AppServices, ContainerRegistries, VM
from diagrams.azure.network import (
    VirtualNetworks,
    Subnets,
    PrivateEndpoint,
    DNSPrivateZones,
)
from diagrams.azure.database import CosmosDb
from diagrams.azure.storage import BlobStorage
from diagrams.azure.identity import ManagedIdentities
from diagrams.azure.ml import CognitiveServices
from diagrams.azure.monitor import LogAnalyticsWorkspaces, ApplicationInsights
from diagrams.azure.general import Subscriptions
from diagrams.onprem.client import User
from diagrams.onprem.compute import Server

graph_attr = {
    "bgcolor": "white",
    "pad": "0.8",
    "nodesep": "0.7",
    "ranksep": "1.0",
    "splines": "spline",
    "fontname": "Arial Bold",
    "fontsize": "18",
    "dpi": "200",
    "labelloc": "t",
}

node_attr = {
    "fontname": "Arial Bold",
    "fontsize": "11",
    "labelloc": "t",
}

cluster_style = {
    "margin": "30",
    "fontname": "Arial Bold",
    "fontsize": "13",
    "style": "rounded",
}

vnet_style = dict(cluster_style, bgcolor="#EAF3FB")
subnet_style = dict(cluster_style, bgcolor="#FFFFFF")
private_paas_style = dict(cluster_style, bgcolor="#F4FAF0")
ops_style = dict(cluster_style, bgcolor="#FFF7E6")

with Diagram(
    "AI Investment Analysis - Private Zero-Trust Architecture\nrg-aiinvest-zt-demo / swedencentral",
    show=False,
    filename="private_architecture",
    direction="LR",
    outformat="png",
    graph_attr=graph_attr,
    node_attr=node_attr,
):

    operator = User("Operator\n(local Mac)")

    with Cluster("Azure subscription\nc91e40f7-...-2a6bf8402aa4", graph_attr=cluster_style):

        uami = ManagedIdentities("UAMI\nid-aiinvest-...\n(ACR pull)")

        with Cluster(
            "Hub VNet  aiinvest-vnet  10.50.0.0/22",
            graph_attr=vnet_style,
        ):

            # --- Operator entry path ---
            with Cluster("AzureBastionSubnet", graph_attr=subnet_style):
                bastion = Subnets("Azure Bastion")

            with Cluster("snet-mgmt  10.50.2.224/27", graph_attr=subnet_style):
                jumpbox = VM("jumpbox\n(SSH + SOCKS5\n127.0.0.1:1080)")

            # --- App Service VNet integration (outbound) ---
            with Cluster(
                "snet-appsvc  10.50.4.0/26\n"
                "delegation: Microsoft.Web/serverFarms\n"
                "serviceEndpoint: Microsoft.CognitiveServices",
                graph_attr=subnet_style,
            ):
                vnet_integ = Subnets("VNet integration\n(WEBSITE_VNET_ROUTE_ALL=1\nPULL_IMAGE_OVER_VNET=true)")

            # --- Private endpoints subnet ---
            with Cluster("snet-pe  10.50.2.0/26", graph_attr=subnet_style):
                pe_api = PrivateEndpoint("PE\naiinvest-api-dev")
                pe_web = PrivateEndpoint("PE\naiinvest-web-dev")
                pe_acr = PrivateEndpoint("PE\nACR")
                pe_cosmos = PrivateEndpoint("PE\nCosmos (Sql)")
                pe_blob = PrivateEndpoint("PE\nStorage (blob)")
                pe_ampls = PrivateEndpoint("PE\nAMPLS\n(LAW + AppInsights)")

            dns = DNSPrivateZones(
                "Private DNS zones\nazurewebsites / azurecr\ndocuments.azure / blob.core\nmonitor / oms / ods\nagentsvc / cognitiveservices\nopenai / services.ai"
            )

        # --- Hosted apps (publicNetworkAccess=Disabled) ---
        with Cluster(
            "App Service Plan  P0v3 (Linux)\nplan-aiinvest-...",
            graph_attr=private_paas_style,
        ):
            api_app = AppServices("aiinvest-api-dev\nDOCKER container\npublic = Disabled")
            web_app = AppServices("aiinvest-web-dev\nDOCKER container\npublic = Disabled")

        # --- Backing PaaS (all private) ---
        with Cluster("Private PaaS dependencies", graph_attr=private_paas_style):
            acr = ContainerRegistries("ACR\naiinvestacr...\npublic = Disabled")
            cosmos = CosmosDb("Cosmos DB (NoSQL)\naiinvest-cosmosdb-...\npublic = Disabled")
            storage = BlobStorage("Storage Account\naiinveststa...\npublic = Disabled")
            ai = CognitiveServices(
                "AI Foundry / OpenAI\naiiuhsfnmz4b6d4zbsz\npublic = Enabled\nnetworkAcls: Deny\n+ VNet rule (snet-appsvc)"
            )

        # --- Observability ---
        with Cluster("Observability (private via AMPLS)", graph_attr=private_paas_style):
            law = LogAnalyticsWorkspaces("Log Analytics\naiinvest-law-...\ningest+query Disabled")
            appi = ApplicationInsights("App Insights\naiinvest-appi-...")

    # =====================================================================
    # Operator path (dashed = control / SSH tunnel)
    # =====================================================================
    operator >> Edge(label="HTTPS 443\n(Bastion tunnel)", style="dashed", color="#8A6D3B") >> bastion
    bastion >> Edge(style="dashed", color="#8A6D3B") >> jumpbox
    jumpbox >> Edge(label="SOCKS5\nbrowse private apps", style="dashed", color="#8A6D3B") >> pe_api
    jumpbox >> Edge(style="dashed", color="#8A6D3B") >> pe_web

    # =====================================================================
    # Inbound app traffic via PE
    # =====================================================================
    pe_api >> Edge(label="resolves via\nprivatelink.azurewebsites.net") >> api_app
    pe_web >> Edge() >> web_app

    # =====================================================================
    # Outbound from apps via VNet integration
    # =====================================================================
    api_app >> Edge(label="all egress\nrouted to VNet", color="#0072C6") >> vnet_integ
    web_app >> Edge(color="#0072C6") >> vnet_integ

    # Web -> API call stays inside VNet
    web_app >> Edge(label="REST", style="dotted", color="#444") >> api_app

    # VNet integ -> dependencies
    vnet_integ >> Edge(label="image pull\n(MI auth)") >> pe_acr >> acr
    vnet_integ >> Edge() >> pe_cosmos >> cosmos
    vnet_integ >> Edge() >> pe_blob >> storage
    vnet_integ >> Edge(
        label="service endpoint\nMicrosoft.CognitiveServices",
        color="#107C10",
    ) >> ai

    # UAMI -> ACR (AcrPull)
    uami >> Edge(label="AcrPull", style="dashed", color="#5C2D91") >> acr

    # Diagnostics -> AMPLS
    api_app >> Edge(label="diag settings", style="dotted", color="#999") >> pe_ampls
    web_app >> Edge(style="dotted", color="#999") >> pe_ampls
    pe_ampls >> Edge(style="dotted", color="#999") >> law
    appi >> Edge(style="dotted", color="#999") >> law

    # DNS resolution (informational)
    vnet_integ >> Edge(style="dotted", color="#888", label="DNS via 168.63.129.16") >> dns
