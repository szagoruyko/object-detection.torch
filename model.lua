require 'nn'
require 'inn'
require 'cudnn'
local matio = require 'matio'

-- Zeiler network
local function createModel(nOutput)
  local features = nn.Sequential()
  
  local fS = {3, 96, 256, 384, 384, 256}
  
  local maxpooling = cudnn.SpatialMaxPooling
  local spatialconv = cudnn.SpatialConvolution
  
  local stride = 2
  local padding = 1
  local ks = 7
  
  features:add(spatialconv(fS[1],fS[2],ks,ks,stride,stride,padding,padding))
  features:add(nn.ReLU())
  features:add(inn.LocalResponseNormalization(3,0.00005,0.75))
  features:add(maxpooling(3,3,2,2))
  
  stride = 2
  padding = 0
  ks = 5
  features:add(spatialconv(fS[2],fS[3],ks,ks,stride,stride,padding,padding))
  features:add(nn.ReLU())
  features:add(inn.LocalResponseNormalization(3,0.00005,0.75))
  features:add(maxpooling(3,3,2,2))
  
  stride = 1
  padding = 1
  ks = 3
  features:add(spatialconv(fS[3],fS[4],ks,ks,stride,stride,padding,padding))
  features:add(nn.ReLU())

  features:add(spatialconv(fS[4],fS[5],ks,ks,stride,stride,padding,padding))
  features:add(nn.ReLU())
  
  features:add(spatialconv(fS[5],fS[6],ks,ks,stride,stride,padding,padding))
  features:add(nn.ReLU())
  
  local modelsdir = '/home/francisco/work/projects/cross_domain/models'
  local mat = matio.load(paths.concat(modelsdir,'Zeiler_conv5_weights.mat'))
  
  local idx = 1
  for i=1,features:size() do
    if torch.typename(features:get(i))=='nn.SpatialConvolutionMM' or 
       torch.typename(features:get(i))=='cudnn.SpatialConvolution' then
      features:get(i).weight:copy(mat['conv'..idx..'_w']:transpose(1,4):transpose(2,3):contiguous():viewAs(features:get(i).weight))
--      features:get(i).weight:copy(mat['conv'..idx..'_w']:contiguous():viewAs(features:get(i).weight))
      features:get(i).bias:copy(mat['conv'..idx..'_b']:squeeze())
      idx = idx + 1
    end
  end
    
    
  
  local classifier = nn.Sequential()
  
  local nOutput = nOutput or 21
  local fS = {12800,4096,4096,nOutput}
  
  classifier:add(nn.Linear(fS[1],fS[2]))
  classifier:add(nn.ReLU())
  classifier:add(nn.Dropout(0.5,true))
  
  classifier:add(nn.Linear(fS[2],fS[3]))
  classifier:add(nn.ReLU())
  classifier:add(nn.Dropout(0.5,true))
  
  classifier:add(nn.Linear(fS[3],fS[4]))
  
  
  local idx = 6
  local last_el = nOutput == 1000 and 0 or 1
  for i=1,classifier:size()-last_el do
    if torch.typename(classifier:get(i))=='nn.Linear' then
      classifier:get(i).weight:copy(mat['fc'..idx..'_w']:transpose(1,2):contiguous():viewAs(classifier:get(i).weight))
--      classifier:get(i).weight:copy(mat['fc'..idx..'_w']:contiguous():viewAs(classifier:get(i).weight))
      classifier:get(i).bias:copy(mat['fc'..idx..'_b']:squeeze())
      idx = idx + 1
    end
  end
  
  local model = nn.Sequential()
  model:add(features)
  model:add(inn.SpatialPyramidPooling({{1,1},{2,2},{3,3},{6,6}}))
  model:add(classifier)
  
  return features,classifier,model
end

-- 1.1. Create Network
features, classifier, model = createModel()

-- 2. Create Criterion
criterion = nn.CrossEntropyCriterion()

print('=> Model')
print(model)

print('=> Criterion')
print(criterion)

-- 3. If preloading option is set, preload weights from existing models appropriately
if opt.retrain ~= 'none' then
  assert(paths.filep(opt.retrain), 'File not found: ' .. opt.retrain)
  print('Loading model from file: ' .. opt.retrain);
  model = torch.load(opt.retrain)
end

-- 4. Convert model to CUDA
print('==> Converting model to CUDA')
model = model:cuda()
criterion:cuda()

collectgarbage()