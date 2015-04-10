require 'torch'
require 'image'
require 'xlua'
local matio = require 'matio'
local argcheck = require 'argcheck'
local xml = require 'xml'

matio.use_lua_strings = true

local DataSetPascal = torch.class('nnf.DataSetPascal')

local function lines_from(file)
-- get all lines from a file, returns an empty 
-- list/table if the file does not exist
  if not paths.filep(file) then return {} end
  lines = {}
  for line in io.lines(file) do 
    table.insert(lines,line)
  end
  return lines
end

--
local initcheck = argcheck{
  pack=true,
  noordered=true,
  help=[[
    A dataset class for object detection in Pascal-like datasets.
]],
  {name="with_hard_samples",
   type="boolean",
   help="",
   default = false},
  {name="image_set",
   type="string",
   help="",
   default="train"},
  {name="year",
   type="number",
   help="",
   default = 2012},
  {name="datadir",
   type="string",
   help="",
   default = "/home/francisco/work/datasets/VOCdevkit/"},
  {name="roidbdir",
   type="string",
   help="",
   default = "/home/francisco/work/libraries/rcnn/data/selective_search_data/"},
  {name="imgsetpath",
   type="string",
   help="",
   default=""},
  {name="classes",
   type="table",
   help="",
   default = {'aeroplane','bicycle','bird','boat','bottle','bus','car',
              'cat','chair','cow','diningtable','dog','horse','motorbike',
              'person','pottedplant','sheep','sofa','train','tvmonitor'},
   check=function(classes)
      local out = true;
      for k,v in ipairs(classes) do
        if type(v) ~= 'string' then
          print('classes can only be of string input');
          out = false
        end
      end
      return out
     end}--[[,
  {name="annopath",
   type="string",
   help="",
   opt = true},
  {name="imgpath",
   type="string",
   help="",
   opt = true},
  {name="roidbfile",
   type="string",
   help="",
   opt = true}]]
}

function DataSetPascal:__init(...)
  
  local args = initcheck(...)
  print(args)
  for k,v in pairs(args) do self[k] = v end
  
  local image_set = self.image_set
  local year = self.year
  
  self.dataset = 'VOC'..year
  
  if not self.annopath then
    self.annopath = paths.concat(self.datadir,self.dataset,'Annotations','%s.xml')
  end
  if not self.imgpath then
    self.imgpath = paths.concat(self.datadir,self.dataset,'JPEGImages','%s.jpg')
  end
  if not self.imgsetpath or self.imgsetpath=='' then
    self.imgsetpath = paths.concat(self.datadir,self.dataset,'ImageSets','Main','%s.txt')
  end
  if not self.roidbfile then
    self.roidbfile = paths.concat(self.roidbdir,'voc_'..year..'_'..image_set..'.mat')
  end
  
  self.num_classes = #self.classes
  self.class_to_id = {}
  for i,v in ipairs(self.classes) do
    self.class_to_id[v] = i
  end
    
  self.img_ids = lines_from(string.format(self.imgsetpath,image_set))
  self.num_imgs = #self.img_ids
  --[[
  self.sizes = {}
  print('Getting Image Sizes')
  for i=1,#self.img_ids do
    xlua.progress(i,#self.img_ids)
    local imp = string.format(self.imgpath,self.img_ids[i])
    table.insert(self.sizes,{image.getJPGsize(imp)})
    if i%100 == 0 then
      collectgarbage()
    end
  end
  self.sizes = torch.IntTensor(self.sizes)
  ]]
  
end

function DataSetPascal:size()
  return #self.img_ids
end

function DataSetPascal:getImage(i)
  return image.load(string.format(self.imgpath,self.img_ids[i]))
end


local function parsePascalAnnotation(ann,ind,parent)
  local res = {}
  for i,j in ipairs(ann) do
    if #j == 1 then
      res[j.xml] = j[1]
    else
      local sub = parsePascalAnnotation(j,i,j.xml)
      if not res[j.xml] then
        res[j.xml] = sub
      elseif #res[j.xml] == 0 then
        res[j.xml] = {res[j.xml]}
        table.insert(res[j.xml],sub)
      else
        table.insert(res[j.xml],sub)
      end
    end
  end
  return res
end

function DataSetPascal:getAnnotation(i)
  local ann = xml.loadpath(string.format(self.annopath,self.img_ids[i]))
  local parsed = parsePascalAnnotation(ann,1,{})
  if parsed.object and #parsed.object == 0 then
    parsed.object = {parsed.object}
  end
  return parsed
end

function DataSetPascal:__tostring__()
  local str = torch.type(self)
  if self:size() > 0 then
    str = str .. ': num samples: '.. self:size()
  else
    str = str .. ': empty'
  end
  return str
end


function DataSetPascal:loadROIDB()
  if self.roidb then
    return
  end
  
  local dt = matio.load(self.roidbfile)
  
  for i=1,#dt.images do
    --assert(dt.images[i]==self.img_ids[i])
  end
  
  self.roidb = {}
  -- compat: change coordinate order from [y1 x1 y2 x2] to [x1 y1 x2 y2]
  for i=1,#self.img_ids do --#dt.images do
    if dt.boxes[i]:size(2) ~= 4 then
      table.insert(self.roidb,torch.IntTensor(0,4))
    else
      table.insert(self.roidb, dt.boxes[i]:index(2,torch.LongTensor{2,1,4,3}):int())
  end
  end
  
end

local function boxoverlap(a,b)
  local b = b.xmin and {b.xmin,b.ymin,b.xmax,b.ymax} or b
    
  local x1 = a:select(2,1):clone()
  x1[x1:lt(b[1])] = b[1] 
  local y1 = a:select(2,2):clone()
  y1[y1:lt(b[2])] = b[2]
  local x2 = a:select(2,3):clone()
  x2[x2:gt(b[3])] = b[3]
  local y2 = a:select(2,4):clone()
  y2[y2:gt(b[4])] = b[4]
  
  local w = x2-x1+1;
  local h = y2-y1+1;
  local inter = torch.cmul(w,h):float()
  local aarea = torch.cmul((a:select(2,3)-a:select(2,1)+1) ,
                           (a:select(2,4)-a:select(2,2)+1)):float()
  local barea = (b[3]-b[1]+1) * (b[4]-b[2]+1);
  
  -- intersection over union overlap
  local o = torch.cdiv(inter , (aarea+barea-inter))
  -- set invalid entries to 0 overlap
  o[w:lt(0)] = 0
  o[h:lt(0)] = 0
  
  return o
end

function DataSetPascal:attachProposals(i)

  if not self.roidb then
    self:loadROIDB()
  end

  local anno = self:getAnnotation(i)
  local boxes = self.roidb[i]
  
  local gt_boxes
  local gt_classes = {}
  local all_boxes
  local valid_objects = {}
  
  if anno.object then
    if self.with_hard_samples then -- inversed with respect to RCNN code
      for idx,obj in ipairs(anno.object) do
        if self.class_to_id[obj.name] then -- to allow a subset of the classes
          table.insert(valid_objects,idx)
        end
      end
    else
      for idx,obj in ipairs(anno.object) do
        if obj.difficult == '0' and self.class_to_id[obj.name] then
          table.insert(valid_objects,idx)
        end
      end
    end
    
    gt_boxes = torch.IntTensor(#valid_objects,4)
    for idx0,idx in ipairs(valid_objects) do
      gt_boxes[idx0][1] = anno.object[idx].bndbox.xmin
      gt_boxes[idx0][2] = anno.object[idx].bndbox.ymin
      gt_boxes[idx0][3] = anno.object[idx].bndbox.xmax
      gt_boxes[idx0][4] = anno.object[idx].bndbox.ymax
      
      table.insert(gt_classes,self.class_to_id[anno.object[idx].name])
    end

    if #valid_objects > 0 and boxes:dim() > 0 then
      all_boxes = torch.cat(gt_boxes,boxes,1)
    elseif boxes:dim() == 0 then
      all_boxes = gt_boxes
    else
      all_boxes = boxes
    end
    
  else
    gt_boxes = torch.IntTensor(0,4)
    all_boxes = boxes
  end

  local num_boxes = boxes:dim() > 0 and boxes:size(1) or 0
  local num_gt_boxes = #gt_classes
  
  local rec = {}
  if num_gt_boxes > 0 and num_boxes > 0 then
  rec.gt = torch.cat(torch.ByteTensor(num_gt_boxes):fill(1),
                     torch.ByteTensor(num_boxes):fill(0)    )
  elseif num_boxes > 0 then
    rec.gt = torch.ByteTensor(num_boxes):fill(0)
  elseif num_gt_boxes > 0 then
    rec.gt = torch.ByteTensor(num_gt_boxes):fill(1)
  else
    rec.gt = torch.ByteTensor(0)
  end
  
  rec.overlap_class = torch.FloatTensor(num_boxes+num_gt_boxes,self.num_classes):fill(0)
  rec.overlap = torch.FloatTensor(num_boxes+num_gt_boxes,num_gt_boxes):fill(0)
  for idx=1,num_gt_boxes do
    local o = boxoverlap(all_boxes,gt_boxes[idx])
    local tmp = rec.overlap_class[{{},gt_classes[idx]}] -- pointer copy
    tmp[tmp:lt(o)] = o[tmp:lt(o)]
    rec.overlap[{{},idx}] = boxoverlap(all_boxes,gt_boxes[idx])
  end
  -- get max class overlap
  --rec.overlap,rec.label = rec.overlap:max(2)
  --rec.overlap = torch.squeeze(rec.overlap,2)
  --rec.label   = torch.squeeze(rec.label,2)
  --rec.label[rec.overlap:eq(0)] = 0
  
  if num_gt_boxes > 0 then
    rec.overlap,rec.correspondance = rec.overlap:max(2)
    rec.overlap = torch.squeeze(rec.overlap,2)
    rec.correspondance   = torch.squeeze(rec.correspondance,2)
    rec.correspondance[rec.overlap:eq(0)] = 0
  else
    rec.overlap = torch.FloatTensor(num_boxes+num_gt_boxes):fill(0)
    rec.correspondance = torch.LongTensor(num_boxes+num_gt_boxes):fill(0)
  end
  rec.label = torch.IntTensor(num_boxes+num_gt_boxes):fill(0)
  for idx=1,(num_boxes+num_gt_boxes) do
    local corr = rec.correspondance[idx]
    if corr > 0 then
      rec.label[idx] = self.class_to_id[anno.object[valid_objects[corr] ].name]
    end
  end
  
  rec.boxes = all_boxes
  if num_gt_boxes > 0 and num_boxes > 0 then
  rec.class = torch.cat(torch.CharTensor(gt_classes),
                        torch.CharTensor(num_boxes):fill(0))
  elseif num_boxes > 0 then
    rec.class = torch.CharTensor(num_boxes):fill(0)
  elseif num_gt_boxes > 0 then
    rec.class = torch.CharTensor(gt_classes)
  else
    rec.class = torch.CharTensor(0)
  end
  
  if self.save_objs then
    rec.objects = {}
    for _,idx in pairs(valid_objects) do
      table.insert(rec.objects,anno.object[idx])
    end
  else
    rec.correspondance = nil
  end
  
  function rec:size()
    return (num_boxes+num_gt_boxes)
  end
  
  return rec
end

function DataSetPascal:createROIs()
  if self.rois then
    return
  end
  self.rois = {}
  for i=1,self.num_imgs do
    xlua.progress(i,self.num_imgs)
    table.insert(self.rois,self:attachProposals(i))
    if i%500 == 0 then
      collectgarbage()
    end
  end
end