#!/usr/bin/env bash
# Garante que o cluster EKS tenha nós Ready.
#
# No AWS Academy, quando a sessão do lab expira as instâncias do node group são paradas e o ASG lança
# substitutas que nascem sem permissão (SCP nega ec2:DescribeInstances à LabRole). O nodeadm falha, o nó
# nunca se registra e os pods ficam Pending. Terminar essas instâncias faz o ASG lançar novas, que nascem
# com a sessão ativa.
#
# Uso: bash infra/script-recuperar-nos.sh [cluster] [região]   (precisa de credenciais AWS e kubeconfig válidos)
set -euo pipefail

CLUSTER="${1:-tech-challenge}"
REGIAO="${2:-us-east-1}"
MAX_TENTATIVAS=3
ESPERA_MAX_SEG=600

nos_prontos() {
  kubectl get nodes --no-headers 2>/dev/null | awk '$2 == "Ready"' | wc -l | tr -d ' '
}

for grupo in $(aws eks list-nodegroups --cluster-name "$CLUSTER" --region "$REGIAO" --query 'nodegroups[]' --output text); do
  asg="$(aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$grupo" --region "$REGIAO" \
    --query 'nodegroup.resources.autoScalingGroups[0].name' --output text)"

  for tentativa in $(seq 1 "$MAX_TENTATIVAS"); do
    if [ "$(nos_prontos)" -gt 0 ]; then
      echo "Cluster $CLUSTER com $(nos_prontos) nó(s) Ready."
      kubectl get nodes
      exit 0
    fi

    # Só termina instâncias que não viraram nó do cluster (as que ainda não registraram).
    registrados="$(kubectl get nodes -o jsonpath='{.items[*].spec.providerID}' 2>/dev/null || true)"
    instancias="$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$asg" --region "$REGIAO" \
      --query 'AutoScalingGroups[0].Instances[].InstanceId' --output text)"

    echo "Tentativa $tentativa/$MAX_TENTATIVAS: sem nós Ready no node group '$grupo' (ASG $asg)."
    for id in $instancias; do
      case "$registrados" in
        *"$id"*) ;;
        *)
          echo "Terminando $id (não registrada no cluster); o ASG lança a substituta."
          aws autoscaling terminate-instance-in-auto-scaling-group --instance-id "$id" \
            --no-should-decrement-desired-capacity --region "$REGIAO" > /dev/null
          ;;
      esac
    done

    echo "Aguardando nós Ready (até ${ESPERA_MAX_SEG}s)..."
    inicio=$SECONDS
    while [ $((SECONDS - inicio)) -lt "$ESPERA_MAX_SEG" ]; do
      [ "$(nos_prontos)" -gt 0 ] && break
      sleep 15
    done
  done
done

if [ "$(nos_prontos)" -gt 0 ]; then
  kubectl get nodes
  exit 0
fi

echo "ERRO: nenhum nó ficou Ready. Confira a sessão do AWS Academy e o console das instâncias (nodeadm)." >&2
exit 1
