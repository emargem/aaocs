#Crea fichero values con todos los values de los charts en la carpeta charts/
salida=values.yaml
echo "Incluyendo global en $salida"
cat global.interno > $salida
for i in `ls charts`
do 
  echo "Incluyendo values.yaml de $i en $salida"
  echo "$i:" >> $salida
  #cat charts/$i/values.yaml >> $salida
  sed 's/^/  /' charts/$i/values.yaml >> $salida
done
